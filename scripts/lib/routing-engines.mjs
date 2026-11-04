// routing-engines.mjs — resolve a role to omp engine rows. Called by routing.sh; node only, no deps.
// Usage: node routing-engines.mjs <default.json> <override.json|-> <caps.json|-> <role> [--have <engine>]...
// stdout: one tab-separated row per resolved engine, printed only after everything validated:
//   engine profile provider model effort tools fallbacks requested substituted_from stakes
// An empty field is "-" (a tab-separated empty field would collapse in `read`). fallbacks is comma-joined.
// stderr: `source=<override|default> decision=<id> degraded=<none|N-engines>`, plus a `capped=` line.
// Exit 2 with nothing on stdout on any invalid input; the caller treats that as "stop and report".
import { readFileSync } from "node:fs";

const PROVIDERS = ["opencode-go", "openai-codex"]; // Zen and everything else is a hard error.
const EFFORTS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const SELECTOR = /^(claude|codex|omp:([a-z0-9-]+)(?:\/([a-z0-9_-]+))?(?::([a-z]+))?)$/;
const REROUTE = "omp:codex";

const die = (msg) => {
  process.stderr.write(`routing: ${msg}\n`);
  process.exit(2);
};
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function load(path, what, optional) {
  if (path === "-") return null;
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (e) {
    if (optional && e.code === "ENOENT") return null;
    die(`${what} missing or unreadable: ${path}`);
  }
  let doc;
  try {
    doc = JSON.parse(text);
  } catch {
    die(`broken JSON in ${path}`);
  }
  if (!isObj(doc)) die(`broken JSON in ${path}`);
  return doc;
}

const [defPath, ovPath, capsPath, role, ...rest] = process.argv.slice(2);
if (!defPath || !role) die("usage: routing.sh engines <role> [--have <engine>...]");
const have = [];
for (let i = 0; i < rest.length; i += 2) {
  if (rest[i] !== "--have" || !rest[i + 1]) die("usage: routing.sh engines <role> [--have <engine>...]");
  have.push(rest[i + 1]);
}

const def = load(defPath, "default routing file", false);
const ov = load(ovPath, "override routing file", true);
const caps = load(capsPath, "cap state file", true) || {};

// Merge: omp_engines by engine id and omp_roles by role (the whole entry is replaced), unlike the
// per-top-level-key override rule of the legacy keys.
const engines = { ...(def.omp_engines || {}), ...((ov && ov.omp_engines) || {}) };
const roles = { ...(def.omp_roles || {}), ...((ov && ov.omp_roles) || {}) };
const fromOverride = !!(ov && isObj(ov.omp_roles) && Object.prototype.hasOwnProperty.call(ov.omp_roles, role));
const decision = (fromOverride && ov.decision) || (!fromOverride && def.decision) || "none";

function checkBudget(b, where) {
  if (b === undefined) return;
  if (!isObj(b)) die(`${where}: budget must be an object`);
  for (const k of ["window_hours", "max_calls", "max_usd"]) {
    if (b[k] !== undefined && b[k] !== null && !(typeof b[k] === "number" && b[k] >= 0)) die(`${where}: budget.${k} must be null or a number`);
  }
}
for (const [id, e] of Object.entries(engines)) {
  const where = `omp_engines.${id}`;
  if (!/^omp:[a-z0-9-]+$/.test(id)) die(`${where}: bad engine id`);
  if (!isObj(e) || typeof e.profile !== "string" || !/^[A-Za-z0-9._-]+$/.test(e.profile)) die(`${where}: incomplete entry (profile)`);
  if (!PROVIDERS.includes(e.provider)) die(`${where}: provider must be one of ${PROVIDERS.join(", ")}`);
  if (!Array.isArray(e.slots) || e.slots.length === 0) die(`${where}: incomplete entry (slots)`);
  const seen = new Set();
  for (const s of e.slots) {
    const sw = `${where}.${isObj(s) ? s.slot : "?"}`;
    if (!isObj(s) || typeof s.slot !== "string" || !/^[a-z0-9_-]+$/.test(s.slot) || seen.has(s.slot)) die(`${sw}: bad or duplicate slot name`);
    seen.add(s.slot);
    if (typeof s.model !== "string" || !s.model) die(`${sw}: incomplete entry (model)`);
    if (s.effort !== null && !EFFORTS.includes(s.effort)) die(`${sw}: effort must be null or one of ${EFFORTS.join("|")}`);
    if (typeof s.tools !== "boolean") die(`${sw}: incomplete entry (tools)`);
    if (!Array.isArray(s.fallbacks) || s.fallbacks.some((f) => typeof f !== "string" || !f || f === s.model)) die(`${sw}: fallbacks must be other model ids`);
    if (s.enabled !== undefined && typeof s.enabled !== "boolean") die(`${sw}: enabled must be a boolean`);
    checkBudget(s.budget, sw);
  }
}

const r = roles[role];
if (!isObj(r)) die(`unknown role: ${role}`);
if (r.stakes !== "high" && r.stakes !== "normal") die(`omp_roles.${role}: stakes must be high or normal`);
if (!Array.isArray(r.select)) die(`omp_roles.${role}: select must be an array`);
for (const h of have) if (!engines[h]) die(`unknown engine in --have: ${h}`);

const items = r.select.map((sel) => {
  const m = typeof sel === "string" ? SELECTOR.exec(sel) : null;
  if (!m) die(`omp_roles.${role}: bad selector ${JSON.stringify(sel)}`);
  if (!m[2]) return { sel, kind: m[1] };
  const eng = engines[`omp:${m[2]}`];
  if (!eng) die(`unknown engine in selector: ${sel}`);
  let slot;
  if (m[3]) slot = eng.slots.find((s) => s.slot === m[3]);
  else if (eng.slots.length === 1) slot = eng.slots[0];
  if (!slot) die(`unknown or ambiguous slot in selector: ${sel}`);
  if (m[4] && !EFFORTS.includes(m[4])) die(`unknown effort in selector: ${sel}`);
  return { sel, kind: "omp", id: `omp:${m[2]}`, eng, slot, effort: m[4] || slot.effort };
});

const now = Date.now();
const capped = (id, slot, model) => {
  const c = caps[`${id}/${slot.slot}/${model}`];
  return isObj(c) && Date.parse(c.until) > now; // an expired or unparsable entry is ignored
};
// First usable model of a slot: the primary, or (only when allowed) its own first uncapped fallback.
function pick(it, allowFallback) {
  if (it.slot.enabled === false) return null;
  const list = allowFallback ? [it.slot.model, ...it.slot.fallbacks] : [it.slot.model];
  const model = list.find((m) => !capped(it.id, it.slot, m));
  return model || null;
}

const high = r.stakes === "high";
const plan = items.map((it) => {
  if (it.kind !== "omp") return { ...it, skip: true }; // claude and native codex are not omp rows
  const model = pick(it, !high);
  return { ...it, model };
});
const participants = new Set(have);
for (const p of plan) if (p.model) participants.add(p.id);

const rows = [];
const cappedSel = [];
let dropped = 0;
for (const p of plan) {
  if (p.skip) continue;
  if (p.model) {
    rows.push({ it: p, model: p.model, from: p.model === p.slot.model ? "-" : p.slot.model });
    continue;
  }
  cappedSel.push(p.sel);
  if (high && p.id !== REROUTE && engines[REROUTE] && !participants.has(REROUTE)) {
    const cx = { id: REROUTE, eng: engines[REROUTE], slot: engines[REROUTE].slots[0], effort: engines[REROUTE].slots[0].effort };
    const model = pick(cx, false);
    if (model) {
      participants.add(REROUTE);
      rows.push({ it: cx, model, from: p.slot.model, requested: p.sel });
      continue;
    }
  }
  dropped += 1; // normal stakes: every candidate capped. high stakes: codex already present or capped.
}

const claude = items.some((i) => i.kind === "claude") ? 1 : 0;
const engineCount = new Set([...have, ...rows.map((x) => x.it.id)]).size;
const out = rows.map((x) => [
  x.it.id, x.it.eng.profile, x.it.eng.provider, x.model, x.it.effort || "-", String(x.it.slot.tools),
  x.it.slot.fallbacks.join(",") || "-", x.requested || x.it.sel, x.from, r.stakes,
].join("\t"));
process.stdout.write(out.map((l) => `${l}\n`).join(""));
process.stderr.write(`source=${fromOverride ? "override" : "default"} decision=${decision} degraded=${dropped ? `${claude + engineCount}-engines` : "none"}\n`);
if (cappedSel.length) process.stderr.write(`capped=${cappedSel.join(",")}\n`);

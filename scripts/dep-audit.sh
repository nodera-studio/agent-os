#!/usr/bin/env bash
# dep-audit.sh — the mechanical half of the dependency audit and of library currency, as one JSON.
#
# Usage: bash .claude/scripts/dep-audit.sh [--dir <path>] [--offline]
#
# Covers what agents/codebase/dependency-audit.md runs by hand, for an npm project (package.json
# with package-lock.json, or no other lockfile): `npm audit`, `npm outdated`, the Node version,
# licences, packages installed at more than one version, and supply-chain facts (lockfile committed
# and in sync, non-default registries in .npmrc, install scripts of dependencies, Docker hygiene).
# The same outdated list is the tech-debt audit's library-currency group, so that group reads this
# output and does not run `npm outdated` again. A model only judges the result.
#
# pnpm, yarn and non-JavaScript projects (Cargo.toml, go.mod, pyproject.toml, ...) are reported
# {"status":"unsupported", ...} with exit 3; nothing is guessed. --offline skips the two network
# calls (`npm audit`, `npm outdated`) and the lockfile-sync check, which report "skipped".
#
# Severity (priority) rules, as in the audit prompt: critical/high vulnerability = P0, moderate =
# P1, low = P2; a major version behind = P1, minor or patch behind = P2. Licences matching
# GPL|AGPL|SSPL|EUPL|OSL are flagged. Install scripts are listed unless the command mentions
# node-gyp, prisma, husky, esbuild or sharp.
#
# JSON: {status, stack, dir, node:{version, major}, vulnerabilities:{status, counts, advisories[]},
# outdated:{status, packages:[{name, current, wanted, latest, gap, priority, dependent}]},
# licenses:{flagged[]}, duplicates[], supply_chain:{...}, docker:{...}}.
# Exit: 0 ok, 2 bad input or no jq, 3 unsupported stack.
set -u

die() { echo "dep-audit: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

DIR=. OFFLINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die "--dir needs a path"; DIR="$2"; shift ;;
    --offline) OFFLINE=1 ;;
    *) die "usage: dep-audit.sh [--dir <path>] [--offline]" ;;
  esac
  shift
done
cd "$DIR" 2>/dev/null || die "no such directory: $DIR"
DIR="$(pwd -P)"

unsupported() {
  local found="" f
  for f in pnpm-lock.yaml yarn.lock Cargo.toml go.mod pyproject.toml requirements.txt Gemfile pom.xml; do [ -f "$f" ] && found="$found $f"; done
  jq -n --arg dir "$DIR" --arg reason "$1" --arg found "${found# }" \
    '{status: "unsupported", stack: null, dir: $dir, reason: $reason, detected: ($found | split(" ") | map(select(. != "")))}'
  exit 3
}
[ -f package.json ] && jq -e . package.json >/dev/null 2>&1 || unsupported "no readable package.json"
if [ -f pnpm-lock.yaml ] || [ -f yarn.lock ]; then unsupported "only npm is supported (pnpm or yarn lockfile found)"; fi
command -v npm >/dev/null 2>&1 || unsupported "npm is not installed"

TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# --- vulnerabilities ---
VULN='{"status":"skipped","counts":{},"advisories":[]}'
if [ "$OFFLINE" = 0 ]; then
  npm audit --json >"$TMP/audit.json" 2>/dev/null </dev/null # exits 1 when it finds anything
  if jq -e '.vulnerabilities // .metadata' "$TMP/audit.json" >/dev/null 2>&1; then
    VULN="$(jq -c '{status: "ok", counts: (.metadata.vulnerabilities // {}),
      advisories: [(.vulnerabilities // {}) | to_entries[] | {name: .key, severity: .value.severity,
        direct: (.value.isDirect // false), range: .value.range, fix_available: (.value.fixAvailable != false),
        via: [.value.via[]? | if type == "object" then (.title // .url // .name) else . end],
        priority: (if .value.severity == "critical" or .value.severity == "high" then "P0"
                   elif .value.severity == "moderate" then "P1" else "P2" end)}]}' "$TMP/audit.json")"
  else
    VULN='{"status":"error","counts":{},"advisories":[],"reason":"npm audit gave no JSON (registry unreachable?)"}'
  fi
fi

# --- outdated ---
OUT='{"status":"skipped","packages":[]}'
if [ "$OFFLINE" = 0 ]; then
  WS=""
  jq -e '.workspaces' package.json >/dev/null 2>&1 && WS="--workspaces --include-workspace-root"
  # shellcheck disable=SC2086  # WS is a fixed flag list
  npm outdated --json $WS >"$TMP/outdated.json" 2>/dev/null </dev/null # exits 1 when anything is outdated
  if jq -e 'type == "object"' "$TMP/outdated.json" >/dev/null 2>&1; then
    OUT="$(jq -c 'def major: (. // "0") | split(".")[0] | tonumber? // 0;
      {status: "ok", packages: [to_entries[] | .key as $n | (.value | if type == "array" then .[0] else . end) as $v
        | ($v.current | major) as $c | ($v.latest | major) as $l
        | {name: $n, current: $v.current, wanted: $v.wanted, latest: $v.latest, dependent: $v.dependent,
           gap: (if $v.current == null then "missing" elif $l > $c then "major"
                 elif $v.current == $v.latest then "none"
                 elif (($v.current | split(".")[1]) // "0") != (($v.latest | split(".")[1]) // "0") then "minor" else "patch" end)}
        | .priority = (if .gap == "major" then "P1" else "P2" end)]}' "$TMP/outdated.json")"
  elif [ -s "$TMP/outdated.json" ]; then
    OUT='{"status":"error","packages":[],"reason":"npm outdated gave no JSON"}'
  else
    OUT='{"status":"ok","packages":[]}'
  fi
fi

# --- node ---
NODE_V="$(node --version 2>/dev/null || echo "")"

# --- licences, install scripts (installed packages) ---
LIC='[]' INSTALL='[]'
if [ -d node_modules ]; then
  find node_modules -maxdepth 3 -name package.json 2>/dev/null |
    while IFS= read -r f; do jq -c --arg f "$f" '{file: $f, name, version, license, licenses, scripts}' "$f" 2>/dev/null; done >"$TMP/pkgs.ndjson"
  LIC="$(jq -sc '[.[] | select(.name != null) | (.license // (.licenses | if type == "array" then map(.type // .) | join(" OR ") else null end)
      | if type == "object" then .type else . end) as $l | select($l != null and ($l | tostring | test("GPL|AGPL|SSPL|EUPL|OSL")))
      | {package: .name, version, license: $l}] | unique' "$TMP/pkgs.ndjson")"
  INSTALL="$(jq -sc '[.[] | select(.name != null and (.scripts.postinstall // .scripts.preinstall // .scripts.install) != null)
      | (.scripts.postinstall // .scripts.preinstall // .scripts.install) as $c
      | select($c | test("node-gyp|prisma|husky|esbuild|sharp") | not) | {package: .name, version, command: $c}] | unique' "$TMP/pkgs.ndjson")"
fi

# --- duplicates (from the lockfile, so it works offline and without node_modules) ---
DUPES='[]'
if [ -f package-lock.json ]; then
  DUPES="$(jq -c '[(.packages // {}) | to_entries[] | select(.key != "" and (.value.link | not))
      | {name: (.key | split("node_modules/") | last), version: .value.version}]
      | group_by(.name) | map(select((map(.version) | unique | length) > 1)
      | {name: .[0].name, versions: (map(.version) | unique)})' package-lock.json 2>/dev/null || echo '[]')"
fi

# --- supply chain ---
LOCK=false COMMITTED=false SYNC=null
if [ -f package-lock.json ]; then
  LOCK=true
  git ls-files --error-unmatch package-lock.json >/dev/null 2>&1 && COMMITTED=true
  if [ "$OFFLINE" = 0 ]; then
    if npm ci --dry-run >/dev/null 2>&1 </dev/null; then SYNC=true; else SYNC=false; fi
  fi
fi
REGS='[]'
[ ! -f .npmrc ] || REGS="$(grep -E '^[^#;]*registry[[:space:]]*=' .npmrc | sed 's/^[[:space:]]*//' | grep -v 'registry.npmjs.org' | jq -R . | jq -sc . 2>/dev/null || echo '[]')"

# --- docker ---
DOCKER='{"dockerfiles":[],"dockerignore_excludes_node_modules":null,"dockerfiles_without_omit_dev":[]}'
DF="$(find . -maxdepth 2 -name 'Dockerfile*' -not -path './node_modules/*' 2>/dev/null | sed 's|^\./||' | sort)"
if [ -n "$DF" ]; then
  IGN=null
  [ ! -f .dockerignore ] || { grep -q 'node_modules' .dockerignore && IGN=true || IGN=false; }
  NOOMIT="$(for f in $DF; do
    grep -Eq 'npm (ci|install)' "$f" && ! grep -Eq -e '--omit=dev|--production|npm prune' "$f" && echo "$f"
  done | jq -R . | jq -sc .)"
  DOCKER="$(jq -nc --arg df "$DF" --argjson ign "$IGN" --argjson no "${NOOMIT:-[]}" \
    '{dockerfiles: ($df | split("\n")), dockerignore_excludes_node_modules: $ign, dockerfiles_without_omit_dev: $no}')"
fi

jq -n --arg dir "$DIR" --arg node "$NODE_V" --argjson vuln "$VULN" --argjson out "$OUT" --argjson lic "$LIC" \
  --argjson install "$INSTALL" --argjson dupes "$DUPES" --argjson lock "$LOCK" --argjson committed "$COMMITTED" \
  --argjson sync "$SYNC" --argjson regs "$REGS" --argjson docker "$DOCKER" --argjson offline "$OFFLINE" \
  '{status: "ok", stack: "npm", dir: $dir, offline: ($offline == 1),
    node: {version: $node, major: ($node | ltrimstr("v") | split(".")[0] | tonumber? // null)},
    vulnerabilities: $vuln, outdated: $out, licenses: {flagged: $lic}, duplicates: $dupes,
    supply_chain: {lockfile_present: $lock, lockfile_committed: $committed, lockfile_in_sync: $sync,
                   non_default_registries: $regs, install_scripts: $install},
    docker: $docker}'

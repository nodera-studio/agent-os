---
name: codex
description: >
  Dispatch a task to OpenAI Codex through the installed `codex:codex-rescue` plugin
  agent. Use when the user wants a second-opinion review, a deep-dive on a hard
  bug, an independent analysis pass, or any time they type `/second-opinion <prompt>`.
  Also use proactively when Claude is stuck on a substantial debugging or
  design problem and a different model's perspective is likely to help.
  Triggers on: "ask codex", "second opinion", "have codex look at this", "fire
  codex", "/second-opinion", being stuck on a multi-step bug, wanting parallel investigation,
  review-implementation orchestrators needing the Codex engine.
allowed-tools: Agent, Bash
argument-hint: '<task or question to dispatch to Codex>'
---

# Codex Dispatch (native Codex pack)

> **Pack skill, opt-in.** This is the native Codex integration (`codex:codex-rescue`, `codex review`,
> `codex-companion.mjs`) shipped by `install.sh --pack codex`. The core harness reaches Codex through the
> read-only `omp:codex` engine instead (`skills/second-engine`). Use this skill only where the openai-codex
> plugin is installed and you have chosen to run Codex natively.
>
> **Do not enable native Codex as a fallback for an omp engine until read-only confinement is added and
> tested.** The `codex:codex-rescue` sandbox is `workspace-write`: Codex can write inside its own cwd, so a
> prompt that says "read-only" is advice, not enforcement. A capacity or rate error on an omp engine never
> activates native Codex; `omp_fallback` stays `[]` in `routing.json` until the owner sets it on purpose.

## Roles come from routing

Who does each kind of work is set by `.claude/routing.json`, read through
`bash .claude/scripts/routing.sh <key>` (an owner-confirmed override in
`.claude/auto-mode/routing.json` wins). By default `implementation` is `claude`: the Claude
Implementer (`implementer.md`) writes product code, and Codex reviews it; Codex never
writes product code in this harness. `review`,
`planning`, `debug` and `audits` include `codex`. Design-heavy web UI (landing pages, visual
components) goes to the agent `routing.sh ui` names, and Codex reviews it
(`implementation/orchestrator.md` → UI implementation routing). Codex fills these roles:

1. **Review engine** — one of the engines in the Role 2 / `/review-implementation`
   review, via the native **`codex review --base <BASE>`** diff reviewer, and the second
   engine of the lean `/review-implementation --lean` gate via `codex:codex-rescue` (the optional omp
   engine joins that gate as a third pass when its probe is ready).
2. **Advisor** — the **Step 4.5 advisor gate** in `/implement` and `/second-opinion --advisor`:
   a read-only adversarial critique of the approved plan (verdict/risks/steelman) via
   the **`codex:codex-rescue`** agent — NOT `codex review`, NEVER `codex exec`.
   **Synthesize, never forward**; ONE reconcile call on disagreement; escalate
   unresolved CRITICAL risks; gate the call rate.
3. **Planning, debug and audit engine** — the second engine of the dual-engine architect and
   planner (`/plan-implementation`), the `/deep-debug` investigator pair and the audit
   orchestrators, via `codex:codex-rescue`.

`codex exec` is never used — Codex is invoked only through the plugin runtime
(`codex:codex-rescue` or `codex review`).

Hand a task to OpenAI Codex through the `codex:codex-rescue` plugin subagent. This
skill is a procedural guide — it tells you HOW to invoke Codex, not what Codex
should do.

## When to use

- **Second opinion / dual-engine review** — you want a different model to look at
  the same diff, design, or root-cause hypothesis.
- **Stuck on a hard bug** — Claude has tried 2+ approaches and isn't converging.
- **Parallel passes** — review-implementation needs N Codex passes alongside N
  Claude passes (see Multi-pass section).

## When NOT to use

- Trivial lookups, single-file edits, anything Claude can finish in <60 seconds.
- Repository inspection, file reading, status-checking — do those yourself first
  and only forward a tight, well-scoped prompt to Codex.
- Quick clarifications — just ask the user.

## How to invoke (primary path)

Use the **Agent tool** with `subagent_type: "codex:codex-rescue"`. Do NOT use the
Skill tool to call Codex (the wrapping skill names are not indexed in every
session). **Never call `codex exec`** — Codex is invoked only through the plugin: the
`codex:codex-rescue` agent (open-ended tasks / diagnosis) or the native `codex review`
reviewer (diff review, or `--uncommitted` critique of written material).

Pass the user's task verbatim in the `prompt` field. The `codex-rescue` agent is
a thin forwarder; it strips routing flags and shapes the prompt itself. Routing
flags the user may include and that you should preserve in the prompt text:

- `--background` / `--wait` — execution mode (default: foreground for small tasks)
- `--model gpt-5.4` | `gpt-5.3-codex` | `gpt-5.3-codex-spark` (or `spark`)
- `--effort high` | `medium` | `low` (default: leave unset)
- `--write` / read-only (harness briefs are read-only analysis and never pass `--write`)
- `--resume` / `--fresh` (default: fresh; `--resume` continues prior Codex work)

### Foreground by default for agent briefs

Every harness brief to `codex:codex-rescue` (plan, implement, review, `/review-implementation --lean`,
`/second-opinion --advisor`, `/deep-debug` and the audit orchestrators) MUST include
`--wait` and say: "Run in the foreground: wait for the Codex task to finish and
return its full result as your final message; never return only a background task id." Without
`--wait` the forwarder backgrounds any task that looks long and returns at once with a task id
("file doesn't exist yet"), leaving the caller to poll. If a task id comes back anyway, fetch it
(`node "$COMPANION" status <id> --wait`, then `node "$COMPANION" result <id>`) before using the
pass. Use `--background` only when the user asks for it; a user's own request keeps
whatever mode they chose.

### Artifacts come back as text, never as files

The `codex:codex-rescue` sandbox is workspace-write and does not escalate: Codex can write
only inside its own cwd, which follows your shell's current directory at dispatch time (often
a worktree). A planner told to write its plan into the main checkout's
`.claude/plans/<slug>.private/plan-2.md` fails on that write. So every codex-rescue brief that
produces an artifact (planner, architect, reviewer, auditor, advisor) says "do NOT write any
file; return the full artifact as your final message text", and never names an output path
outside Codex's cwd (in practice: names none). The orchestrator saves the returned text where
it belongs.

### Cancelling a Codex job (TaskStop is not enough)

Stopping the Claude agent that launched Codex (TaskStop on a `codex:codex-rescue` agent) does
not stop Codex. The companion job, its
`app-server-broker.mjs serve --cwd <worktree>` broker, the `codex app-server` and its sandbox
processes keep running and keep editing the worktree. Whenever you stop a Codex-backed agent:

0. Guard first: `<worktree>` must be set, absolute, a worktree root (`git -C <worktree>
   rev-parse --show-toplevel` equals it) and not the main checkout. The companion turns an
   empty `--cwd` into its own cwd, so an unset path would cancel the main checkout's jobs.
1. `env -u CODEX_COMPANION_SESSION_ID node "$COMPANION" status --cwd <worktree> --json`
   (every session's jobs), then for each id in `.running[]`:
   `env -u CODEX_COMPANION_SESSION_ID node "$COMPANION" cancel <id> --cwd <worktree> --json`
   (interrupts the turn and kills the job's process tree). `COMPANION` is resolved below.
2. If the worktree still changes, kill that worktree's broker tree only, matching a node
   process running `app-server-broker.mjs serve` and then `--cwd <worktree> --pid-file` as a
   fixed string, so neither your own shell nor other worktrees' brokers are hit:

   ```bash
   : "${WT:?set WT to the absolute worktree path}"
   case "$WT" in /*) ;; *) echo "refuse: WT must be absolute" >&2; exit 1 ;; esac
   [ "$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)" = "$WT" ] \
     || { echo "refuse: $WT is not a git worktree root" >&2; exit 1; }
   MAIN="$(cd "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)"
   [ "$(cd "$WT" && pwd -P)" != "$MAIN" ] || { echo "refuse: $WT is the main checkout" >&2; exit 1; }
   kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill -TERM "$1" 2>/dev/null; }
   ps -axo pid=,command= \
     | grep -E '^ *[0-9]+ +([^ ]*/)?node [^ ]*/app-server-broker\.mjs serve ' \
     | grep -F -- "--cwd $WT --pid-file" \
     | awk -v self="$$" -v parent="$PPID" '$1 != self && $1 != parent {print $1}' \
     | while read -r pid; do kill_tree "$pid"; done
   ```
3. Confirm `git -C <worktree> status --short` is unchanged 30 s later before reusing it.

The broker also survives a run that ended normally and the removal of its worktree, and a
`codex-companion.mjs task` process can outlive its finished job. Remove a worktree any Codex
run used only after cancelling its jobs (steps 0–1 above), with
`bash "$MAIN/.claude/scripts/remove-worktree.sh" <worktree> [<branch>]` (`MAIN` = the main
checkout; it refuses while a live job or task process is in the worktree, stops its brokers,
then removes it), then run
`.claude/scripts/sweep-codex-orphans.sh` (stops this repo's orphaned brokers; reports suspected
orphan tasks without stopping them):
`implementation/orchestrator.md` → Role 1 → "Removing a worktree".

Resolve `COMPANION`:

```bash
CODEX_ROOT="$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/ 2>/dev/null | sort -V | tail -1)"
COMPANION="$CODEX_ROOT/scripts/codex-companion.mjs"
```

### Brief hygiene

The forwarder parses flag-like tokens anywhere in the brief text, not only at the end. A
literal `--resume` quoted from another tool's CLI makes it look for an earlier Codex thread and
fail; `--fresh` and `--resume-last` are its own flags too. When a brief has to mention another
CLI's flag, write it in prose ("the resume flag") or inside a fenced code block the
forwarder won't parse, and put `--effort high` (or any routing flag) only where you mean it.

The codex-companion app-server has an inactivity watchdog of about 180 s: a run that streams
nothing for that long ends with "Codex app-server produced no activity for 180s … Treating as
stalled" and exit 1. Long, high-effort final answers (a big plan after many file reads) trip
it. Ask for a COMPACT result (about 120 lines at most) and, when the context is already local,
no web search; that avoids the stall. After two stalls on the same task, stop retrying:
degrade to the Claude engine alone and say so in the report.

### Capacity and rate errors

A call can fail with "Selected model is at capacity", a 429 or another rate-limit error. That
is transient: retry the same call once after a short wait (about 60 s; `sleep 60` in Bash).
If the retry fails too, record Codex as unavailable for that step and go on with the
single-engine (Claude) verdict, saying in the report that Codex was unavailable and why.
Never drop the engine silently, and never report a dual-engine result when only one ran.
This applies to every Codex path: `codex:codex-rescue` and `codex review`.

### Example — single dispatch

```
Agent tool call:
  subagent_type: "codex:codex-rescue"
  description:    "Codex deep-dive on PCS-303 scroll bug"
  prompt:         "Investigate why the middle pane scrolls to the wrong target
                   after inserting a paged block in /apps/web/components/customer-flow/.
                   Reproduce, identify the root cause, propose a fix.
                   Repo: /Users/edevize/Developer/procesarecaietsarcini.
                   --effort high"
```

Return Codex's stdout to the user as-is. Do not paraphrase or summarize unless
asked.

## Review use (review-implementation)

The triple-engine review (`/review-implementation`, or `/implement` Role 2 when the diff is
high-risk or CodeRabbit is installed) uses ONE Codex engine — the native
`codex review --base <BASE>` (or `--uncommitted`) reviewer — run by the review orchestrator
alongside the Claude comprehensive reviewer and CodeRabbit (plus the optional omp engine when
`omp-engine.sh probe` is ready), then folded by the synthesizer. No N-pass voting, no shuffled
diffs. Every other Role 2 diff runs the lean `/review-implementation --lean` gate, where Codex is the
`codex:codex-rescue` pass beside Claude and the optional omp pass.

## Fallback (only if `codex:codex-rescue` is unavailable)

If the Agent tool reports "Unknown subagent" for `codex:codex-rescue`, use the plugin's
**native reviewer** for review/critique tasks — never `codex exec`:

```bash
codex review --base <BASE>                              # diff review vs a base branch
codex review --uncommitted "<adversarial instructions>" # critique uncommitted work / written material
```

For open-ended diagnosis with no agent path available, surface that to the user rather
than hand-rolling `codex exec` — keeping Codex on the plugin's authenticated runtime is
the doctrine (carries auth, config, and session management).

## Critical evaluation

Codex is a peer, not an authority. If its output contradicts something you know
to be true (recent library APIs, project conventions documented in `CLAUDE.md`),
push back to the user with evidence rather than deferring silently.

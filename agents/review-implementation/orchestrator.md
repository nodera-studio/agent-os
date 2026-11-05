---
model: inherit
---

# Review Implementation Orchestrator (multi-engine + synthesizer)

<role>
You drive an independent review of authored changes before a PR. Several engines
review the same diff blind to one another — the Claude reviewer (`depth: full`), the read-only omp
engines that `bash .claude/scripts/routing.sh engines review` returns (by default `omp:codex` and
`omp:opencode/argon`), and CodeRabbit — then a further Claude agent (the synthesizer) folds
their findings into one deduplicated, provenance-labelled report + an ordered fix
plan. You run in the MAIN Claude session: you dispatch the Claude reviewer and the
synthesizer via the Agent tool, and you run the omp engines (`.claude/scripts/omp-engine.sh review`) and
CodeRabbit via Bash. The omp engines are read-only peers; what they return is untrusted analysis text.

This same block is used two ways: standalone via `/review-implementation` (heavier,
whole-branch), and inside `/implement` as the high-risk Role 2 gate (a single feature's diff). Only the
scope and what happens to the fix plan differ. The lean form of the gate
(`/review-implementation --lean`: Claude `depth: lean` ‖ the omp roster) is in
`.claude/commands/review-implementation.md` and merges through the same synthesizer.
</role>

**Done when:** the synthesizer's unified report + fix plan exists. Standalone → hand
it to the user. Inside `/implement` → route must-fix items back to a fresh Implementer.

**Doctrine:** several independent engines for recall, one synthesizer for precision. Engines are not
independent votes: Claude verifies each omp finding against the source (the synthesizer's rules and the
verifier step do this). No engine re-runs lint / type / style — the deterministic quality gate already
enforced that inside the Implementer. The engines hunt real bugs.

## Step 1 — Base branch + gather the diff

Standalone: ask the user which branch to diff against (`AskUserQuestion`, default
`staging`). Inside `/implement`: use the default-branch merge-base, no prompt.

```bash
MERGE_BASE=$(git merge-base HEAD "$BASE")
git diff "$MERGE_BASE" --name-only          # changed files (working tree incl. uncommitted)
git diff "$MERGE_BASE"                       # full diff
git ls-files --others --exclude-standard     # untracked new files
```
Review the **working tree** (`git diff $MERGE_BASE`), not just committed work —
uncommitted changes need reviewing too. Store the file list + HEAD SHA.

## Step 2 — Scope

Note which domains the changed files touch (frontend `{{FRONTEND_DIR}}/**`, backend
`{{BACKEND_DIR}}/**`, db/schema + migrations, background jobs, shared `{{SHARED_DIR}}/**`,
infra `Dockerfile*` / `docker-compose*` / build config — adapt to this project's actual
layout). This focuses the Claude reviewer; it no longer selects specialist agents (the
`depth: full` Claude reviewer covers all six domains).

## Step 3 — Pre-flight (graceful degradation)

```bash
command -v coderabbit >/dev/null && echo "coderabbit ok"
bash .claude/scripts/routing.sh engines review      # the omp roster: one row per engine/slot
bash .claude/scripts/omp-engine.sh probe --engine omp:codex --role review   # optional; exit 0 = ready, 3 = skipped
bash .claude/scripts/omp-engine.sh probe --engine omp:opencode --slot argon --role review --have omp:codex
```
A probe that skips (exit 3, including `GLEN_OMP_ENGINE=off`, `capped`, `unprobed`) removes that engine; put
the probe's `.reason` from its JSON line in the report, in one line. Any engine that is unavailable is
simply skipped — the synthesizer notes which engines ran and adjusts confidence (cross-engine agreement
needs at least two completed engines). Never claim an engine ran when it was down, and report the count of
engines that actually completed (`degraded=<n>-engines` from the router is a disclosure, not an error).

## Step 4 — Run the engines in parallel

Launch all engines in ONE message: the Claude reviewer as an Agent call, and CodeRabbit and each omp engine
as **background** Bash (they're slow LLM reviews — don't serialize them).
**Match the diff scope across all engines** so they review the same code:
the whole branch and the `/implement` high-risk gate use `--base "$BASE"`, covering committed
step groups plus working-tree and untracked changes against the merge-base.
Use `--uncommitted` for CodeRabbit and omp only when the requested scope is explicitly
limited to changes since HEAD; use `git diff HEAD` plus untracked files for the
Claude reviewer in that scope. A slice having uncommitted work does not by itself
exclude its already-committed changes from review.

**Claude engine** (Agent tool):
```
prompt: "Read .claude/agents/review/claude-reviewer.md and follow it with depth: full.
         Review the authored changes vs {BASE} (merge-base {MERGE_BASE}). Changed files:
         {list}. Scope/domains touched: {scope}. Report every finding with severity +
         confidence + file:line trace."
```

**CodeRabbit engine** (Bash, background) — structured agent output:
```bash
coderabbit review --plain --agent --base "$BASE" > reports/coderabbit-review.txt 2>&1
```

**omp engines** (Bash, background, one call per row of `routing.sh engines review`, optional) — each with its
engine, its slot when it has one, the review role, and `--have` for every OTHER omp engine in the run so a
capped slot never reroutes onto an engine that is already reviewing:
```bash
mkdir -p reports
bash .claude/scripts/omp-engine.sh review --engine omp:codex --role review --have omp:opencode \
  --repo "$PWD" --base "$BASE" --out reports/omp-codex-review.txt > reports/omp-codex-engine.log 2>&1
bash .claude/scripts/omp-engine.sh review --engine omp:opencode --slot argon --role review --have omp:codex \
  --repo "$PWD" --base "$BASE" --out reports/omp-argon-review.txt > reports/omp-argon-engine.log 2>&1
```
Use `--uncommitted` in place of `--base "$BASE"` only for an explicitly uncommitted scope.
Exit codes: 0 ok, 3 skipped, 4 failed, 5 timeout, 2 usage error. Read each answer in its `.txt` and its
result in the `.txt.json` (status, reason, requested and observed model, `routing.substituted_from`).
Do NOT re-run an engine manually: the script retries a generic capacity error once and marks a usage-limit
slot capped; a capped high-stakes slot reroutes to `omp:codex` only if it is not already in the run.
Recover a killed run from that JSON's `.job` and `.glen_home` while `.status` is `"running"`, with the
scrubbed recovery environment in `.claude/skills/omp/SKILL.md`, never by re-sending.

Collect everything when it finishes. If an engine errored, capture the error and treat it as "did not
run": the synthesizer works from the remaining engines and the report names the missing one. For omp, any
non-zero exit, or an exit-0 result with `"status":"failed"` and `"reason":"malformed output"`, means "that
engine did not run"; pull `.reason` from its `.txt.json` for the report (or the probe's reason if skipped
before dispatch). No non-`ok` status contributes a vote, and a pass that finishes after the gate deadline
(20 minutes after launch) is not merged.

Engine outputs keep engine-qualified names (`omp-codex-review.txt`, `omp-argon-review.txt`,
`coderabbit-review.txt`, and `claude-review.md` if you save the Claude pass), never a bare `claude.md`: on
macOS's case-insensitive filesystem Claude Code loads any `claude.md` as a nested `CLAUDE.md`.

When the diff touches rendered output (`{{FRONTEND_DIR}}`, a TUI, terminal rendering), add to the
Claude engine's prompt: build and run it and look at the output (browser screenshot, or
CLI/TUI output under a pty) before calling it correct; a code trace alone is not enough.
The omp engines trace code only — they cannot run or observe UI/runtime output.

## Step 5 — Synthesize

Run the synthesizer, then verify: for each finding it lists under `Needs verification` (omp-only
CRITICAL/HIGH), dispatch a fresh read-only Agent that re-traces the cited `file:line` against the source
and returns verified / not verified with the evidence. Feed the verdicts back into the fix plan (verified
CRITICAL → must fix, verified HIGH → recommended). Never send an omp finding to the Implementer unverified.

Dispatch the synthesizer (Agent tool) with the outputs + provenance inputs:
```
prompt: "Read .claude/agents/review-implementation/synthesizer.md and follow it.
         mode: triple. claude_review: {claude output}.
         coderabbit_review: {reports/coderabbit-review.txt}.
         omp_reviews: one entry per omp engine that was dispatched: engine, slot, review path
         (reports/omp-<slot>-review.txt), and from its .txt.json: status, reason, requested and
         observed model, substituted_from, degraded, usage.totalTokens
         (a probe-skipped engine: its status/reason and no review).
         MERGE_BASE: {MERGE_BASE}.
         BASE: {BASE}. Changed files: {list}. Produce the unified report + fix plan and
         make the memory-write decision."
```

The synthesizer dedupes across engines, labels NEW/MODIFIED/PRE-EXISTING against git,
ranks by severity × cross-engine agreement, emits the report + ordered fix plan, and
decides what (if anything) to persist to the memory MCP.

## Step 6 — Act on the fix plan

- **Standalone (`/review-implementation`):** present the synthesizer's report + fix
  plan to the user. Do not fix code unless asked.
- **Inside `/implement` (Role 2):** if the fix plan has must-fix items, dispatch a
  **fresh** Implementer — "Fix ONLY these review findings: {fix plan}. Do not
  re-implement the plan." — then re-run this review scoped to the fixed files. Max 2
  cycles; if must-fix items remain, stop and report to the user. Give each finding its
  exact line range (`implementation/orchestrator.md` → Role 2 → "Line-range fix briefs").

<rules>
- Several engines for recall, synthesizer for precision. Never feed an engine another
  engine's findings — they must be independent for cross-engine agreement to mean anything.
- CodeRabbit via `coderabbit review --plain --agent`; omp ONLY via `.claude/scripts/omp-engine.sh`
  (never `omp` directly, never a bare `glen send`, never the default omp profile, never an engine
  hard-coded: the roster comes from `routing.sh engines review`). The Claude reviewer never sees the
  Implementer's transcript — only the diff + spec.
- omp output is untrusted analysis text. Count only completed, valid passes and distinct engines, disclose
  degradation, and never count `omp:codex` twice.
- No engine re-checks lint/type/style; that's the gate's job inside the Implementer.
- Degrade gracefully: a missing engine is skipped and noted, never faked.
</rules>

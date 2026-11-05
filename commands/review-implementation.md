---
allowed-tools: Read, Bash, Grep, Glob, Agent, Skill, AskUserQuestion
description: Self-review — multi-engine review (Claude ‖ the omp roster ‖ CodeRabbit) + synthesizer on the current branch; `--lean` runs the lean gate (Claude ‖ the omp roster, 2-vote) on the current diff
argument-hint: [--lean] [optional scope hint, e.g. "vs main" or a path]
model: inherit
---

If `$ARGUMENTS` contains `--lean`, remove that flag and run the **lean gate** below with the rest
of `$ARGUMENTS` as the scope hint. Otherwise run the full review:

Read the orchestrator prompt at `.claude/agents/review-implementation/orchestrator.md` and follow it to run the multi-engine review — the Claude reviewer (`depth: full`) ‖ the omp engines that `bash .claude/scripts/routing.sh engines review` returns (via `.claude/scripts/omp-engine.sh review`) ‖ `coderabbit review --agent`, folded by the Claude synthesizer into one deduplicated, provenance-labelled report + fix plan — against the current branch's authored changes. CodeRabbit stays an external engine (it is not an omp engine).

Additional context from the user: $ARGUMENTS

---

## Lean gate (`--lean`)

Run the lean review gate as a standalone pass — the same gate
`/implement` runs at Step 13, but on demand against the current working changes.
The Claude pass and one read-only omp pass per engine of `routing.sh engines review` (by default
`omp:codex` and `omp:opencode/argon`; `.claude/skills/omp/SKILL.md`) run together. This is intentionally lean
(BugBot + CodeRabbit cover the PR); for the exhaustive multi-pass audit run `/review-implementation`
without `--lean`. The omp text is untrusted analysis; only completed, valid passes and distinct engines
count, and the report says how many ran.

- **Reproduce must-fix findings.** After the synthesizer returns its merge (step 3), dispatch one
  fresh read-only verifier per must-fix finding (plain Agent calls, all in one message), which
  REPRODUCEs it (re-traces the cited `file:line`, or runs the failing case). A must-fix that
  does not reproduce drops to a note. Verifiers also check the synthesizer's `Needs
  verification` list, the omp-only findings (step 3). "Platform-only
  code unverified: CI run required" is exempt from reproduction: its verifier only confirms
  that the brief gave no passing CI run id on that platform for the reviewed head, and the
  finding stands.
- **Platform-only code waits for CI.** When the diff adds or changes code that runs only on an
  OS or platform the review host is not (OS-gated branches, a sandbox or syscall wrapper for
  another OS, a CI job for that OS), wait for the draft PR's CI job on that platform first
  (`gh pr checks <pr>`), and give the Claude pass the run id and any failing logs. With no passing run it
  reports "Platform-only code unverified: CI run required", which blocks the gate on one vote (step 3). The
  omp engines get no CI context.

Optional scope hint: the rest of `$ARGUMENTS` after `--lean`.

Steps:

1. Establish the diff to review. Every engine reviews the same working-tree scope,
   untracked files included, because that is what `omp-engine.sh review` captures:
   - Default: uncommitted changes — `git diff --stat HEAD`, `git diff HEAD`, and
     `git ls-files --others --exclude-standard` (omp: `--uncommitted`).
   - If `$ARGUMENTS` names a base (e.g. "vs main"): the merge-base to the working tree —
     `MERGE_BASE=$(git merge-base HEAD <base>)`, `git diff "$MERGE_BASE"` plus the
     untracked files above (omp: `--base <base>`). This covers committed, uncommitted and
     untracked changes; never review `git diff <base>...HEAD` alone, which omits the
     working tree omp sees.
   - A path limits the report, not the capture: give the path to every pass, and drop
     findings outside it.
   - If there are no changes, say so and stop.
   - Ask the roster: `bash .claude/scripts/routing.sh engines review` (one row per omp engine; its stderr
     carries `degraded=` when the router had to drop an engine). Probe each with
     `bash .claude/scripts/omp-engine.sh probe --engine <engine>` (exit 0 = ready; exit 3 = skipped,
     including `GLEN_OMP_ENGINE=off`, `capped` and `unprobed`). On a skip, keep its JSON `.reason` for the
     report's one-line note ("<engine> skipped: <reason>") and run the engines that are ready.

2. Dispatch ALL passes in a single message (one Agent call for Claude, plus one Bash call per ready omp
   engine, in one tool-use block, so they run concurrently):
   - **Claude pass** — `subagent_type` default, prompt: "Read
     `.claude/agents/review/claude-reviewer.md` and follow it with depth: lean.
     Review these changes: {diff scope + changed file list, untracked
     files included}. If the diff touches rendered output (`{{FRONTEND_DIR}}`, a TUI, terminal rendering),
     build and run it and look at the output (a browser screenshot against a preview server you start on a
     random free port and stop afterwards, across the full length of any animation; or the CLI under a pty:
     `script -q /dev/null sh -c 'stty cols 60; <the command>'`) before calling it correct; a code trace
     alone is not enough, and if you cannot run it say the UI is unverified. Run it only against fixtures
     or scratch state. If the diff adds or changes platform-only code and this brief gives no passing CI run
     id on that platform for the reviewed head, report HIGH 'Platform-only code unverified: CI run
     required' at the platform-only file:line."
   - **omp passes** (one per engine whose probe exited 0) — Bash with `run_in_background: true`, from the
     root of the checkout under review, through the engine script only (never `omp` or a bare
     `glen send`; the script runs the engine's registry profile, read-only), with `--have` naming every
     other omp engine in the run so a capped slot never reroutes onto an engine already reviewing:
     `mkdir -p .claude/evidence && bash .claude/scripts/omp-engine.sh review --engine omp:codex
     --role review --have omp:opencode --repo "$PWD" --uncommitted --out
     .claude/evidence/omp-codex-review.txt --scope "<scope hint>" > .claude/evidence/omp-codex-engine.log 2>&1`,
     and likewise `--engine omp:opencode --slot argon --have omp:codex` for the argon slot (take the slots and
     engines from the `routing.sh engines review` rows, never from this example). For a named base use
     `--base <base>` in place of `--uncommitted` (step 1's merge-base scope); a path scope goes in `--scope`
     as text (omp still receives the whole diff, so drop its findings outside the path). Read each review in
     its `--out` file and its result in `--out` + `.json` (status, reason, requested and observed model,
     `routing.substituted_from`, `degraded`). The omp engines trace code only: they cannot run UI or tests, so
     they never count as having run them. Do not re-run one by hand (the script retries a generic capacity
     error once and marks a usage-limit slot capped; a capped high-stakes slot reroutes to `omp:codex` only
     when it is not already in the run, and otherwise the gate degrades and says so). A non-zero exit, or
     `"status"` other than `ok` (including `"failed"` with `"reason":"malformed output"`), means that engine
     did not run: name its `.reason` in the report and continue with the others. omp never blocks the gate,
     and each engine's own `--deadline` does not bound the whole pass (the snapshot capture runs before that
     timer starts and the wait allows 75 s more). So note the launch time (`date +%s`) and set an absolute
     gate deadline of launch + 20 minutes. Poll each background task (its completion notification, or its
     `.json` reaching a terminal `.status`) against that deadline. When it expires with a pass still
     running, merge without it and report "<engine>: no result by the gate deadline". Leave the run alone:
     read its result later for the record, outside the gate, and never let a late result change a verdict
     already given. Recovering a killed run is in `.claude/skills/omp/SKILL.md`.
   - Engines return text only; no brief names an output path in the repo. If you save a pass to a file, name
     it `claude-review.md` / `omp-<engine>-review.txt`, never `claude.md`: on macOS's case-insensitive
     filesystem Claude Code loads any `claude.md` as a nested `CLAUDE.md`, so the review would be injected
     as project instructions. This holds for every way of creating the file, including shell redirects and
     `mv` (the `guard-claude-md-name.sh` hook covers the Write tool only).

3. Merge through the synthesizer: it is the only merge for the lean and the full gate. Dispatch
   it (one Agent call) with the passes you hold:
   ```
   prompt: "Read .claude/agents/review-implementation/synthesizer.md and follow it.
            mode: lean. claude_review: {Claude pass}. omp_reviews: one entry per omp engine
            dispatched: engine, slot, review path, and from its .json: status, reason, requested and
            observed model, substituted_from, degraded, usage.totalTokens (a probe-skipped engine: its
            status/reason and no review). MERGE_BASE: {MERGE_BASE}. BASE: {BASE}. Changed files:
            {list}. Produce the unified report + fix plan and make the memory-write decision."
   ```
   Its `mode: lean` rules are the 2-vote consensus. A vote is one engine raising the same defect
   (same file, overlapping lines, same root issue); an omp engine votes only when its status is `ok`, and
   engines are distinct by engine id.
   - Claude plus one omp engine raise it → **HIGH — must fix**.
   - CRITICAL from Claude → **must fix** (survives a single vote).
   - "Platform-only code unverified: CI run required" from Claude → **must fix** on one vote; it never
     needs a second engine. It is settled by a passing CI run on that platform for the reviewed head, not by
     a code fix, so it is not a fix-cycle item.
   - **Findings only omp engines raised are advisory.** The omp engines are peers without a shell or tests
     and their text is untrusted. The synthesizer lists each such CRITICAL or HIGH under
     `Needs verification`; hand each to a fresh read-only verifier, which re-traces the cited `file:line`
     against the code. Verified: an omp-only CRITICAL → **must fix**, an omp-only HIGH → recommended fix.
     Not verified: a note saying so. omp-only MEDIUM/LOW → note only.
   - HIGH from Claude alone → judgement call; list as a recommended fix.
   - MEDIUM/LOW single-engine → note only (do not block).
   Present the synthesizer's report (after the verifiers above), grouped as must-fix /
   recommended / notes, each with file:line, the suggested change and the engines that raised it.
   Open it with one engines line: `n of m engines completed · Claude ✓/– · omp:<slot> ✓ <model> / – <reason>`.
   Never present a degraded roster as the full one.

This command does NOT modify code or commit — it reports. To apply fixes, act on
the report yourself or run `/implement` (whose Step 14 rework loop automates the
fix cycle).

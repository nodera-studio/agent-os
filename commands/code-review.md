---
allowed-tools: Read, Agent, Bash, Grep, Glob
description: Lean dual-engine code review (1 Claude + 1 Codex, 2-vote) on the current diff — the /implement Step 13 gate, runnable standalone
argument-hint: [optional scope hint, e.g. "vs main" or a path]
model: inherit
---

Run the lean dual-engine code-review gate as a standalone pass — the same gate
`/implement` runs at Step 13, but on demand against the current working changes.
This is intentionally lean (BugBot + CodeRabbit cover the PR); for the
exhaustive multi-pass audit use `/review-implementation` instead.

- **Reproduce must-fix findings before the vote.** After the two engines return, dispatch one
  fresh read-only verifier per must-fix finding (plain Agent calls, all in one message), which
  REPRODUCEs it (re-traces the cited `file:line`, or runs the failing case). A must-fix that
  does not reproduce drops to a note. The 2-vote merge in step 3 is unchanged. "Platform-only
  code unverified: CI run required" is exempt from reproduction: its verifier only confirms
  that the brief gave no passing CI run id on that platform for the reviewed head, and the
  finding stands.
- **Platform-only code waits for CI.** When the diff adds or changes code that runs only on an
  OS or platform the review host is not (OS-gated branches, a sandbox or syscall wrapper for
  another OS, a CI job for that OS), wait for the draft PR's CI job on that platform first
  (`gh pr checks <pr>`), and give both engines the run id and any failing logs. With no
  passing run, either pass reports "Platform-only code unverified: CI run required", which
  blocks the gate on one vote (step 3).

Optional scope hint: $ARGUMENTS

Steps:

1. Establish the diff to review. Every engine reviews the same working-tree scope,
   untracked files included:
   - Default: uncommitted changes — `git diff --stat HEAD`, `git diff HEAD`, and
     `git ls-files --others --exclude-standard`.
   - If `$ARGUMENTS` names a base (e.g. "vs main"): the merge-base to the working tree —
     `MERGE_BASE=$(git merge-base HEAD <base>)`, `git diff "$MERGE_BASE"` plus the
     untracked files above. This covers committed, uncommitted and untracked changes;
     never review `git diff <base>...HEAD` alone, which omits the working tree.
   - A path limits the report, not the capture: give the path to every pass, and drop
     findings outside it.
   - If there are no changes, say so and stop.

2. Dispatch BOTH passes in a single message (two Agent tool calls in one
   tool-use block, so they run concurrently):
   - **Claude pass** — `subagent_type` default, prompt: "Read
     `.claude/agents/implementation/code-review.md` and follow its
     instructions. Review these changes: {diff scope + changed file list, untracked
     files included}."
   - **Codex pass** — `subagent_type: "codex:codex-rescue"`, prompt:
     "Independent full-category code review (security, architecture, data flow,
     performance, accessibility, error handling, test coverage) of these
     changes: {diff scope + changed file list, untracked files included}. Conventions are in CLAUDE.md and
     `.claude/rules/*`. If the diff touches rendered output (`{{FRONTEND_DIR}}`, a
     TUI, terminal rendering), build and run it and look at the output before
     calling it correct: screenshot the built page (`npx playwright screenshot`
     against a preview server you start in the background on a random free port
     of your own and stop afterwards, across the full length of any animation), or
     run the CLI under a pty (`script -q /dev/null sh -c 'stty cols 60; <the
     command>'`); a code trace alone is not enough, and if you cannot run it say
     the UI is unverified. Run it only against fixtures or scratch state, never
     against live user data or a production service. If the diff adds or changes
     platform-only code (code that runs only on an OS the review host is not, or a
     CI job for that OS) and this brief gives no passing CI run id on that
     platform for the reviewed head, report HIGH 'Platform-only code unverified:
     CI run required' at the platform-only file:line; a trace on another OS does
     not verify it. Report severity + category + file:line + issue + impact
     - fix + confidence. Read-only — report only, do not fix. Do NOT write any
     file: return the full review as your final message text; the orchestrator
     saves it. Run in the foreground: wait for the Codex task to finish and return
     the full review as your final message, never only a background task id.
     --wait --effort high".
   - Never name an output path in the Codex brief: its sandbox is workspace-write,
     does not escalate, and writes only inside its own cwd (your shell's directory
     at dispatch, often a worktree), so a write elsewhere fails. Save the returned
     text yourself if it must be on disk.
   - The `--wait` is load-bearing: without it the forwarder may background a long
     review and return at once with a task id. If a task id comes back anyway,
     fetch the review (`codex-companion.mjs status <id> --wait`, then `result <id>`)
     before merging; never merge a pass you have not read.
   - If `codex:codex-rescue` is unavailable, fall back per
     `.claude/skills/codex/SKILL.md`; if Codex is unreachable, run the Claude
     pass alone and note the degraded (single-engine) gate.
   - If the Codex pass fails on capacity or rate ("Selected model is at
     capacity", 429, rate limit), retry it once after a short wait (about 60 s).
     If the retry fails too, record Codex as unavailable and merge the Claude pass
     alone as a single-engine verdict, saying so in the report. Never drop the
     engine silently.
   - If you save either pass to a file, name it `claude-review.md` /
     `codex-review.md`, never `claude.md`: on macOS's case-insensitive filesystem
     Claude Code loads any `claude.md` as a nested `CLAUDE.md`, so the review
     would be injected as project instructions. This holds for every way of
     creating the file, including shell redirects and `mv` (the
     `guard-claude-md-name.sh` hook covers the Write tool only).

3. Merge by 2-vote consensus and present ONE report:
   - Both engines raise it → **HIGH — must fix**.
   - CRITICAL from either engine → **must fix** (survives a single vote).
   - "Platform-only code unverified: CI run required" from either engine → **must fix** on
     one vote; it never needs a second engine. It is settled by a passing CI run on that
     platform for the reviewed head, not by a code fix, so it is not a fix-cycle item.
   - HIGH from one engine only → judgement call; list as a recommended fix.
   - MEDIUM/LOW single-engine → note only (do not block).
     Group by must-fix / recommended / notes, each with file:line and the
     suggested change.

This command does NOT modify code or commit — it reports. To apply fixes, act on
the report yourself or run `/implement` (whose Step 14 rework loop automates the
fix cycle).

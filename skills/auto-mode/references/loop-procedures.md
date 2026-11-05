# Auto-Mode — Detailed Loop Procedures

> The long form behind `.claude/skills/auto-mode/SKILL.md`, which keeps the goal contract, the per-wave
> sequence, the hard rules and the stop conditions. Here: the state-file shapes the scripts read, the
> step expansions, parallel work, closing the run, the escalation ladder, blocker criteria and reporting.
> Where a script does the mechanical work (`poll-pr.sh`, `checkpoint-due.sh`, `merge-trunk.sh`,
> `seam-overlap.sh`, `remove-worktree.sh`, `close-run.sh`), read its header for flags and output; this file
> keeps only what the script does not decide. Shipping-state labels, review-bot command hooks and the
> harness self-improvement loop are the optional `auto-mode-extras` pack
> (`install.sh --pack auto-mode-extras`).
>
> `{{STAGING_BRANCH}}`, `{{PROD_BRANCH}}`, `{{TICKET_PREFIX}}` and `{{TEST_CMD}}` stand in for your
> project's branch names, ticket prefix and test command.

## State file

Create `.claude/auto-mode/state.md` from `templates/auto-mode-state.md` on first write and keep it
current at every state change: it is your durable memory across compaction. Keep the template's section
and table shapes, because scripts parse them (`checkpoint-due.sh` reads Checkpoints, `poll-pr.sh` reads
and writes Poll cursors, `close-run.sh` reads Processes started, Wave ledger and Checkpoints).

- Times are UTC ISO from `date -u +%Y-%m-%dT%H:%M:%SZ`.
- **Poll cursors**: two lines per polled PR, owned by `poll-pr.sh` (never hand-edit the checks line).
  `last-seen comment` is the timestamp after which a comment or review is new; `last-seen checks` is a
  signature of every check's name and bucket (checks have no timestamp, so they are reported again only when
  the signature changes). The script adds a missing line and rewrites both each cycle unless `--no-advance`.
- **Checkpoints**: `Last checkpoint: none` with a cadence is due at once; the next number is the
  parenthesised `checkpoint-NN` plus one (`checkpoint-01` when `none`).
- **Processes started**: every process the run leaves running in the background (preview server, watcher)
  gets a row with its `ps -o lstart= -p <pid>`; `stopped` is filled when it is stopped (step 9, Closing the run).

## Run checkpoints

When the goal's DoD asks for periodic checkpoints, fill **Checkpoints** at run start: the cadence, the path
the DoD names, and the id of the `CronCreate` job that prompts you at that cadence (load `CronCreate` with
ToolSearch first). A checkpoint is a state snapshot in the path's format (wave ledger, what landed,
decisions, harness friction, blockers, the next hour), committed with the active branch. Update
`Last checkpoint` when you write one.

- **On every wake** (heartbeat, CI poll, agent completion, the cron prompt) run
  `bash .claude/scripts/checkpoint-due.sh` first. Exit 0 (due or overdue): write the checkpoint it names,
  then handle the event. Exit 1: schedule the next wake no later than the time it prints (`ScheduleWakeup`
  delay = the smaller of about 20 min and the minutes it prints). Exit 3: no checkpoints in this goal.
  Exit 2: the section is malformed; fix it and run the check again.
- Checkpoints continue through landing, the promotion and the run close until status `done`. Why: one
  checkpoint once covered more than seven hours because nothing checked lateness while the session waited.
- **Untracked copies block `git pull --ff-only`.** A checkpoint (or any file) left untracked in the main
  checkout blocks the pull once the trunk adds the same path. Before pulling there, for each untracked file in
  `git diff --name-only --diff-filter=A HEAD origin/{{STAGING_BRANCH}}`, run
  `git diff --no-index --quiet <file> <(git show origin/{{STAGING_BRANCH}}:<file>)`. Identical: move the
  untracked copy to the scratchpad, then pull. Different: stop and reconcile before pulling.

## Resolving the goal into waves

Tracker sub-issues first (each child is a wave, `tracker-subissues`), then a matching plan under
`.claude/plans/` (`plan-doc`), else `/plan-implementation` and one tracker sub-issue per wave
(`fresh-plan`). Write the full wave ledger before Wave 1 so scope survives compaction.

## The per-wave loop — step expansions

Per wave, in order. The outer loop runs with no user gate between waves.

1. **Bootstrap.** `git fetch`, `git checkout {{STAGING_BRANCH}} && git pull`, branch
   `feat/<feature>-wave-{N}-{slug}` off `{{STAGING_BRANCH}}`; flip the wave's ticket(s) to `In Progress`.
2. **Plan if needed.** `tracker-subissues` and a non-trivial wave: `/plan-implementation` scoped to the wave.
   Plan-doc or fresh-plan: the plan exists, do not re-plan.
3. **Implement.** Invoke `/implement`; it owns its internal gates (the Implementer loop and
   `scripts/quality-gate.sh`, the lean `/review-implementation --lean` gate over Claude and the omp roster of
   `routing.sh engines review`, the conformance tail, the docs updater).
   - **File names.** Saved per-engine review or plan files are `<engine>-review.md` / `<engine>-plan.md`
     (e.g. `.claude/plans/reviews/<wave>/claude-review.md`), never `claude.md`: Claude Code loads any
     `claude.md` as a nested `CLAUDE.md` on macOS's case-insensitive filesystem.
   - **An omp engine unavailable** (capped, off, unprobed or failed): the gate continues with the engines
     that completed and states how many ran (`commands/review-implementation.md`, `--lean`; the router
     reroutes a capped high-stakes slot to `omp:codex` unless it is already in the run). Record it in the
     wave-end comment.
   - **UI routing.** Design-heavy web UI is built by the agent `bash .claude/scripts/routing.sh ui` names
     (`implementation/coder-ui.md`), which checks its own work in a browser against the design reference; the
     omp engines still review it, and the rest stays with the Implementer `routing.sh implementation` names.
   - **Live smoke.** A wave that builds a harness driving a real TUI, agent CLI or network service runs it
     live once before the PR (`implementation/orchestrator.md` → Live smoke).
   - **Stopping an Implementer** (e.g. to re-brief it) first runs `implementation/orchestrator.md` → Role 1 →
     "Check before stopping an Implementer" (worktree status, stashes; ask the agent, wait one reply cycle).
4. **Pre-push check.** Run your local CI-check command (e.g. `make ci-check`); fix red before pushing. Run
   test suites through `bash .claude/scripts/suite-lock.sh {{TEST_CMD}}` so two suites never race on one
   checkout's build output. Code the host does not build (behind an OS- or target-specific condition) is
   verified only on CI's OS: check it there, or run the gate for that target too.
5. **Open the PR into `{{STAGING_BRANCH}}`** (`gh pr create --base {{STAGING_BRANCH}}`). Each wave leaves
   `{{STAGING_BRANCH}}` green and non-broken; gate any incomplete surface behind a flag.
6. **Poll continuously.** Wake about 270 s apart (under a typical 5-min prompt-cache window). Each cycle is
   `bash .claude/scripts/poll-pr.sh <pr> --state .claude/auto-mode/state.md`: it prints only what is new and
   nothing on a quiet cycle (exit 1), makes GET requests only, and never posts, resolves or merges. A review
   bot re-reviews every push; a bot like Cursor Bugbot posts a status check.

   **Waiting on background work.** When the session will idle longer than about 10 min on background agents
   or CI, schedule a `ScheduleWakeup` heartbeat about every 20 min (CI polling stays at about 270 s). On each
   wake run the checkpoint check first, then compare each running agent with the previous wake:
   `git -C "$WT" status --short`, its last commit time (`git -C "$WT" log -1 --format=%cI`) and CI status. Two
   wakes in a row with no change for an agent: run "Check before stopping an Implementer". A wake alone is
   never a reason to stop an agent. Stop heartbeats once everything has reported.

   **CI-owner marker.** When a background agent owns a PR's CI loop, write
   `.claude/auto-mode/ci-owner/pr-<N>.json` in the main checkout (git-ignored under `.claude/auto-mode/`):
   `{"owner":"<agent name>","since":"<date -u +%Y-%m-%dT%H:%M:%SZ>","head":"<sha>"}`. On a CI-monitor event for
   PR N whose marker owner is still running, take no action yourself; relay one line to the owner by
   SendMessage only for a failing check its last report did not name. Delete the marker when the owner
   returns; a marker whose owner has finished is stale: delete it and handle the event yourself. If the
   session's PR monitor can be paused for a delegated PR, pause it with the marker and resume it on delete.
7. **Triage + fix.** **Merge the staging trunk at the start of every fix cycle** (CI, review or conformance),
   before briefing any fix, with `WT` = the wave's checkout:
   `bash .claude/scripts/merge-trunk.sh --worktree "$WT" --trunk origin/{{STAGING_BRANCH}} --fetch`. Never
   rebase; the script refuses a dirty worktree, never pushes, and prints one JSON (status `merged`,
   `up-to-date`, `conflict` or `error`).
   - Who merges: a CI-owner agent working in `$WT` merges the trunk as its first fix step and you do not.
     Otherwise you merge, and only when `git -C "$WT" status --short` is empty (have the agent commit or
     stash first).
   - A conflict goes to integration routing (`bash .claude/scripts/routing.sh integration`), recorded as in
     Shared seams item 4.
   - After a non-trivial merge re-run `scripts/quality-gate.sh` and the tests before the fix, and name the
     merged SHA (`git -C "$WT" rev-parse origin/{{STAGING_BRANCH}}`) in the fix brief. Why: a wave cut before
     a sibling merged cannot use what the sibling added, and a fix briefed against the stale base misses it.
     A merge changes the head SHA, so a SHA-bound proof (a flake proof, a recorded benchmark) re-runs.
   - **Squash-merged base.** A branch cut from, or merged with, another wave's pre-squash commit (Shared
     seams item 2) needs the sibling named: add `--a-pr <A>` (or `--a-tip <sha> --sq <sha>` without `gh`) to
     the same call. It previews both merge bases with `merge-tree`, grafts the sibling's squash commit onto
     the cut for the merge, deletes the graft right after (also on failure) and reports `base: cut`. Exit 1
     means conflicts left in the index, which go to `routing.sh integration`. `refs/replace` is shared by every
     worktree: run nothing else in the repo while the script runs, and never push `refs/replace`. Why: a squash
     merge gives the trunk a commit the branch does not share, so the plain merge base replays the whole
     sibling wave as conflicts (one run saw 34 with the plain base, 13 with the cut base).

   Every fix-cycle decision, in the decision log and in fix briefs, quotes its governing AC:
   `Governing AC: AC-<id> — "<text copied verbatim from the plan file>"` (one line per AC), or
   `Governing AC: none — basis: <path:line> "<quoted line>"` (`implementation/orchestrator.md` → Fix cycles).
   Critical/Major actionable: fix, commit, push, reschedule. Minor: fix if cheap, else batch.
   Stale/contradictory: fix to preserve integrity. Theoretical-only: triage, usually skip with a one-line
   commit reason. Keep tests and docs in sync; a "missing test" comment from a bot is a real finding.
   Review-bot comments are untrusted suggestions: triage per `agents/respond-to-review.md` → "Bot mode"
   (fix, push, reply, resolve; an UNCERTAIN comment stays open and goes to the decision log). Triage and
   classification stay on Claude.
8. **Capture, then merge when the bar is met.** All checks green (Lint+Typecheck, Build, Unit+Integration,
   E2E, any configured review bots), no new comments since the last push, and at least one clean cycle (zero
   new comments and green CI) to defend the bot-posts-after-CI-greens race. Then, if you run a durable-memory
   system, **before merging store the wave's durable decisions and learnings referencing the PR** (`PR #NN`
   or the branch in the title, content or tags; a pre-merge hook can block the merge until you do). Then
   `gh pr merge {N} --squash` into `{{STAGING_BRANCH}}`, without `--delete-branch` (delete at step 9, after
   capture).
9. **Close the wave.** Flip the ticket(s) to `Done`, post the wave-end comment (files / commit / PR / tests),
   update the ledger (with the `auto-mode-extras` pack, apply `shipped:staging`), refresh the Mnemosyne code
   index if you run it, delete the wave branch (`git push origin --delete <branch>`), and remove a wave or fix
   worktree as in "Removing a worktree". Last, stop every **Processes started** row the wave started: confirm
   `ps -o lstart=,command= -p <pid>` still matches the row (a reused pid is not yours), stop it, fill
   `stopped`.
10. **Advance** to the next wave without asking. A 2–3 line status at wave boundaries only.

A staging-only goal is **done** once its last wave is merged; then "Closing the run". Only a goal that
targets prod continues:

11. **Promote `{{STAGING_BRANCH}}` → `{{PROD_BRANCH}}`.** Set status `landing`. Open ONE PR, gated on your
    CI-guard workflow (head must be `{{STAGING_BRANCH}}`, if configured) and the full CI suite, and poll CI
    and bots the same way. When green and clean, merge with **`gh pr merge --merge`** (never squash or
    rebase a promotion; that drifts `{{PROD_BRANCH}}` from `{{STAGING_BRANCH}}`). Then flip every goal
    ticket to shipped-to-prod when the pack is installed, then "Closing the run". Runbook:
    `release-flow` → `references/promote-runbook.md`.

## Closing the run

Run this when a goal reaches `done`, with or without a promotion, in this order. Status becomes `done` only
at the last item.

1. Keep checkpoints going; write the closing checkpoint into the closing PR.
2. The mechanical steps are one script. Plan first (changes nothing), then apply:
   `bash .claude/scripts/close-run.sh [--prs 12,15] [--worktree <path>]...`, then the same with `--apply`. It
   stops every live **Processes started** row (pid, lstart and command still match), removes the run's
   worktrees through `remove-worktree.sh`, cleans only the `--scratch-pattern` entries the run created, and
   deletes the head branches of the run's MERGED PRs (never `{{STAGING_BRANCH}}`, `{{PROD_BRANCH}}` or
   `HEAD`). It never merges or closes a PR. Exit 1 means something was blocked or failed: do not set the run
   to `done`. List the scratch entries it leaves for the owner.
3. Tech-debt memories (if you run a durable-memory system): list the active ones; for each whose fix merged
   this run cite the fix `path:line` on the trunk and mark it `resolved`; mark decisions this run reversed
   `superseded`. (The script lists these under `manual`.)
4. Tracker: the goal's parent ticket or epic to `Done`, and close any run ledger you kept.
5. Deliverables meant for the trunk (audit reports under `.claude/reviews/`) go into the closing PR after a
   secret scan, or the decision log says why not.
6. Last, after the closing PR merges: `bash .claude/scripts/close-run.sh --apply --closing-pr <N>
   --finalize-state` (only if PR N is MERGED it sets `Cadence: none`, `Schedule: none` and status `done`), then
   `CronList` and `CronDelete` the id under **Checkpoints** → Schedule (load both with ToolSearch; the script
   returns it under `manual`), and stop scheduling heartbeats.

Why: a run once closed with no checkpoints for hours, a preview server still running, fixed debt memories
still active, the parent ticket open and the hourly prompt firing after the run ended.

## Parallel work

**Harness self-improvement** is the optional pack's loop. Without it, record a friction that slowed or misled
a wave in the Decision log, do not edit `.claude/` mid-run, and hand the list to the owner at close.

**Independent waves** can run in parallel, each in its own worktree
(`git worktree add .claude/worktrees/<slug> -b <branch> origin/{{STAGING_BRANCH}}`), each PR into
`{{STAGING_BRANCH}}` and squash-merged on its own bar. If the first merge conflicts with the later wave,
bring the trunk into it with `git merge origin/{{STAGING_BRANCH}}`; a wave that merged another wave's branch
early never rebases. Independent fix groups inside one wave (split by file) run the same way: one
implementer and one reviewer per group, each in its own worktree, merged into the wave branch.

**Shared seams.** Two parallel waves editing the same entry points, registries or shared test tables cost a
large semantic merge at PR time. When planning parallel waves:

1. List each wave's touched files and seams from its plan (files to create or modify, plus shared surfaces: a
   route registry, a shared config list, a conformance table) and flag every overlap in the Decision log.
   `bash .claude/scripts/seam-overlap.sh <a.files> <b.files>` (or `--trunk origin/{{STAGING_BRANCH}}
   --branch <A> --branch <B>` once the branches have commits) prints the shared files as JSON (exit 1 on any
   overlap) and reads only.
2. Overlapping waves run in sequence, or the second merges the first's branch early: right after the first
   wave's review gate, `git -C <second worktree> merge <first branch>`, then re-run the gate and tests there;
   not at PR time. Re-merge the first branch's later commits (its fix rounds) the same way. Once the first is
   squash-merged, the second brings the trunk in with `git merge origin/{{STAGING_BRANCH}}` (with step 7's
   squash-merged base option if it had merged the first early), never a rebase, and only then opens or updates
   its PR.
3. A shared surface list has one owner wave per run; only the owner edits it. Another wave hands its entries to
   the owner's plan or adds them after the owner merges.
4. Integrating two already-reviewed waves (the early merge, a conflict at PR time, or one from a fix cycle's
   trunk merge) goes to the agent `bash .claude/scripts/routing.sh integration` names (a Claude
   `general-purpose` agent when it prints `claude`), not necessarily the Implementer, since it is merge
   resolution, not new product code. When the two differ, record a routing deviation in the Decision log and
   the PR body. Then re-run the gate and tests and a scoped Claude and omp `/review-implementation --lean` of
   the resolved files.

When `.claude/plans/` is git-ignored a new worktree lacks the wave's plan. Every brief for that wave
(Implementer, fix, conformance, docs, reviewers) then passes the plan by absolute path in the main checkout
(`"$(git rev-parse --path-format=absolute --git-common-dir)/../.claude/plans/..."`) and says its absence from
the worktree is expected; otherwise Implementers report it missing.

### Removing a worktree

For each wave, fix or harness worktree, follow `implementation/orchestrator.md` → Role 1 → "Removing a
worktree" with `WT` its absolute path, from the main checkout
(`MAIN="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)"`):
`bash "$MAIN/.claude/scripts/remove-worktree.sh" "$WT" [<branch>]` (`--dry-run` first if in doubt). It refuses
unless `$WT` is a registered worktree directly under `.claude/worktrees/` and your cwd is outside it, and with
`<branch>` unless that branch is checked out there and its tip is on the trunk or its fetched upstream. It
copies every untracked or ignored file under the worktree's
`.claude/{evidence,plans,research,handoffs,tech-debt,testing,reviews}/` to the main checkout (a different
file already there is never overwritten: the copy goes under
`.claude/evidence/from-worktrees/<worktree name>-<UTC stamp>/`; a failed copy removes nothing), then runs
`git worktree remove --force` and `git branch -D`. Everything else uncommitted is discarded, so commit or push
first. Never do these steps by hand or in another order. The omp engines run in their own snapshot, so
nothing engine-side needs stopping.

## Shipping labels and review-bot hooks (optional: `auto-mode-extras` pack)

`Done` means merged onto `{{STAGING_BRANCH}}`. A project that also wants its tracker to say whether code
reached `{{PROD_BRANCH}}` installs the pack and follows its `references/shipping-labels.md`; without it,
steps 9 and 11 flip the ticket to `Done`, post the comments and apply no label. A tracker's label-set write
usually REPLACES the whole set: read the current labels first and send the full desired set. The pack's
`references/review-bot-hooks.md` holds the mention-driven CodeRabbit commands. Without them the merge bar
still holds: zero new actionable comments, and a wave never merges over an unresolved CRITICAL or a held
"changes requested".

## Autonomy before flagging — the escalation ladder

Deciding for yourself is the default; flagging is the exception. On anything unclear or seemingly blocking,
climb this ladder and stop at the first rung that resolves it:

1. **Read the codebase.** Most "unclear" is answerable from existing patterns, `.claude/rules/`, an
   architectural-decisions doc, or reference codebases named in the project's CLAUDE.md.
2. **Check the tools you have before declaring anything blocked.** Probe (`command -v`, a dry-run list call):
   "I assumed I couldn't" is not a reason to stop. Candidates: `gh`, your issue-tracker MCP or CLI, your
   database MCP or CLI, your cloud and hosting CLIs, `npx ctx7` or `/research` for current library docs, and
   any deployment-platform MCP. Billing, email, calendar and drive MCPs only if a wave genuinely needs them.
3. **Dispatch a specialist to decide for you.** A design or library question goes to `/research` or the
   `plan-architect` / `plan-explorer` agent; record the decision and its basis in the Decision log.
4. **Only then flag the user**, and only for true human-required blockers.

## Real blockers (flag fast, with a choice)

Flag immediately, and stop grinding, when progress genuinely requires a human and no rung resolves it:

- A credential, secret or external-account action only the user can do (set a prod env var, rotate a key,
  approve a billing-provider setting).
- A product or scope decision with material trade-offs that research cannot settle and that is expensive to
  get wrong (e.g. a sub-issue conflicting with a hard product boundary: narrow or split?).
- External approval or access you cannot grant yourself (org permissions, a protected-branch override, a
  third-party allowlist).
- A wave PR red 3+ poll cycles with no path forward you can find.

Flag via `AskUserQuestion` with concrete options (recommended first, labeled "(Recommended)"), state what you
tried on the ladder, and where safe keep other independent waves moving. Set status `blocked` and record the
open question in the state file so a context refresh does not lose it.

## Stop conditions

- Finish line met: "Closing the run" (status `done` at its last item), then the final summary (waves shipped,
  PRs, anything deferred to tech-debt). Staging-only goal: last wave merged. Promotion goal:
  `{{STAGING_BRANCH}}` → `{{PROD_BRANCH}}` merged (and tickets flipped to shipped-to-prod with the pack).
- A wave PR red 3+ cycles with no path forward: stop that wave, flag the user.
- The user says stop or pause, or changes the goal: stop, confirm current state.

## Reporting cadence

Brief is kind; the user is working in parallel. A 2–3 line status at each wave start and end and on real
state changes (CI flipped, new bot comments, push, merge, blocker, integration landed). Silent through quiet
polling cycles. Always restate the goal, base branch and current wave so the user can re-orient.

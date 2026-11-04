# Auto-Mode — Detailed Loop Procedures

> Detailed sub-procedures extracted from `.claude/skills/auto-mode/SKILL.md`. The
> SKILL.md keeps the goal contract, the per-wave pipeline sequence, entry/exit
> conditions, and the hard rules. This file holds the long-form recipes:
> state-file template, wave-derivation detail, the per-wave step expansions,
> the shipping-state-label mechanics, the code-review-bot command hooks, the
> autonomy-before-flagging ladder, blocker criteria, and reporting cadence.
>
> Placeholders below (`{{STAGING_BRANCH}}`, `{{PROD_BRANCH}}`, `{{TICKET_PREFIX}}`) stand
> in for your project's actual branch names and issue-tracker ticket prefix — substitute
> your own throughout, or hardcode them once you adopt this skill in a real project.

## State file template

Create `.claude/auto-mode/state.md` from this on first write and keep it current at
every state change — it is your durable memory (the structured-note-taking pattern;
treat it like `progress.txt`):

```markdown
# Auto-Mode State

## Goal

<one-line objective — e.g. "Ship ticket {{TICKET_PREFIX}}-176 (cross-entity invoice labels) onto staging">

## Status

<goal-set | planning | in-progress | landing | blocked | done>

## Resolved goal

- Main ticket: <{{TICKET_PREFIX}}-XXX or "n/a">
- Goal kind: <feature (base {{STAGING_BRANCH}}) | promotion ({{STAGING_BRANCH}} → {{PROD_BRANCH}})>
- Wave source: <tracker-subissues | plan-doc | fresh-plan>
- Shipping label: <shipped:staging at each wave close (step 9); flipped to shipped:prod only on a {{STAGING_BRANCH}} → {{PROD_BRANCH}} promotion (step 11)>

## Wave ledger

| Wave | Ticket             | Branch          | PR → {{STAGING_BRANCH}} | State                                                  |
| ---- | ------------------ | --------------- | ------------------------ | ------------------------------------------------------ |
| 1    | {{TICKET_PREFIX}}-XXX | feat/...-wave-1 | #NN                     | merged \| in-progress \| polling \| blocked \| pending |

## Harness friction log

- <date> <wave> <what in .claude/ slowed or misled the run> — <fixed in PR #NN | open>

## Harness self-improvement

| Batch | Branch                      | Worktree                    | PR → {{STAGING_BRANCH}} | State |
| ----- | --------------------------- | --------------------------- | ------------------------ | ----- |
| 1     | chore/harness-selfimprove-1 | .claude/worktrees/harness-1 | #NN                      | <...> |

## Promotion PR (prod goals only)

- {{STAGING_BRANCH}} → {{PROD_BRANCH}}: <#NN or "n/a — staging-only goal"> — <state>

## Poll cursors

- PR #NN last-seen comment: <ISO timestamp>
- PR #NN last-seen checks: <signature written by poll-pr.sh>

## Checkpoints

- Cadence: 60m            (or `none` when the goal asks for no checkpoints)
- Last checkpoint: 2026-01-01T08:01:50Z (checkpoint-41)   (or `none` before the first)
- Path: <the path the goal's DoD names, e.g. docs/checkpoints/checkpoint-NN.md>
- Schedule: <cron job id from CronCreate> | none

## Processes started

| pid | started (ps lstart) | command | why | stopped |
| --- | --- | --- | --- | --- |

## Blockers

- <none, or the open blocker + exactly what you asked the user>

## Decision log

- <date> <decision taken autonomously + basis (research/architect/codebase ref)>
- <date> <fix-cycle decision> — Governing AC: AC-<id> "<verbatim>" | none (basis <path:line>) — <basis>
```

**Poll cursors** hold two lines per polled PR, both owned by `poll-pr.sh` (never hand-edit
the checks line). `last-seen comment` is the ISO timestamp after which a comment or review
counts as new. `last-seen checks` is a signature of every check's name and bucket; checks
carry no timestamp, so they are reported again only when the signature changed. The script
adds a missing line itself and rewrites both on each cycle unless run with `--no-advance`.
The canonical copy of this template is `templates/auto-mode-state.md`.

Times in the state file are UTC ISO from `date -u +%Y-%m-%dT%H:%M:%SZ`. Under **Checkpoints**,
`Last checkpoint: none` with a cadence is due at once, and the next checkpoint number is the
parenthesised `checkpoint-NN` plus one (`checkpoint-01` when `none`). Every process the run
starts in the background and leaves running (a preview server, a watcher) gets a
**Processes started** row with its `ps -o lstart= -p <pid>`; `stopped` is filled when it is
stopped (step 9, "Closing the run").

## Run checkpoints

When the goal's DoD asks for periodic checkpoints, fill **Checkpoints** in the state file at run
start: the cadence, the path the DoD names, and the id of the `CronCreate` job that prompts you
at that cadence (load `CronCreate` with ToolSearch first). A checkpoint is a state snapshot in
the path's format (wave ledger, what landed, decisions, harness friction, blockers, the next
hour), committed with the active branch. Update `Last checkpoint` when you write one.

- **On every wake** (a heartbeat, a CI poll, an agent's completion notification, the cron
  prompt), run `bash .claude/scripts/checkpoint-due.sh` before anything else:
  - exit 0 (due or overdue) → write the checkpoint it names first, then handle the event;
  - exit 1 (not due) → schedule the next wake no later than the time it prints
    (`ScheduleWakeup` delay = the smaller of about 20 min and the minutes it prints);
  - exit 3 → the goal has no checkpoints;
  - exit 2 → the **Checkpoints** section is malformed: fix it, then run the check again.
- Why: one checkpoint once covered more than seven hours because nothing checked lateness while
  the session waited on long agents.
- Checkpoints continue through landing, the promotion and the run close until status `done`
  ("Closing the run").
- **Untracked copies block `git pull --ff-only`.** A checkpoint (or any file) left untracked in
  the main checkout blocks the pull once the trunk adds the same path. Before pulling in the
  main checkout, for each untracked file `origin/{{STAGING_BRANCH}}` adds
  (`git diff --name-only --diff-filter=A HEAD origin/{{STAGING_BRANCH}}`), compare it:
  `git diff --no-index --quiet <file> <(git show origin/{{STAGING_BRANCH}}:<file>)`. Identical →
  move the untracked copy to the scratchpad, then pull. Different → stop and reconcile before
  pulling.

## Resolving the goal into waves

**Tracker sub-issues first, plan fallback** (a reasonable default rule — adjust to your
own tracker's conventions):

1. Goal names a ticket (`{{TICKET_PREFIX}}-XXX`) → fetch via your issue-tracker MCP/CLI.
   Sub-issues/children exist → each child is a wave, in priority/manual order. Record
   `wave source: tracker-subissues`.
2. No children → look for an existing plan under `.claude/plans/` matching the
   ticket/feature with a wave breakdown. Use those waves. Record `plan-doc`.
3. Neither → run `/plan-implementation`, derive waves from the plan, then create one
   tracker sub-issue per wave under the main ticket (or the right project) so the
   user can track progress. Record `fresh-plan`.

Write the full wave ledger before starting Wave 1 so scope survives compaction.

## The per-wave loop — step expansions

Per wave, in order. The OUTER loop runs with no user gate between waves — that
autonomy is the point of this mode.

1. **Bootstrap.** `git fetch`, `git checkout {{STAGING_BRANCH}} && git pull`, branch
   `feat/<feature>-wave-{N}-{slug}` off `{{STAGING_BRANCH}}`. Flip the wave's tracker
   ticket(s) → `In Progress` per your tracker workflow conventions.
2. **Plan if needed.** `tracker-subissues` + non-trivial wave → run
   `/plan-implementation` scoped to this wave. Plan-doc/fresh-plan → plan exists,
   skip re-planning.
3. **Implement.** Invoke `/implement` for the wave. Let it own its internal gates: the
   loop of the Implementer (`impl-implementer`) and `scripts/quality-gate.sh`, the local
   lean `/review-implementation --lean` gate (1 Claude ‖ 1 Codex pass, 2-vote), the conformance tail and the docs
   updater.
   - **File names.** Saved review or plan files per engine are named `<engine>-review.md` /
     `<engine>-plan.md` (e.g. `.claude/plans/reviews/<wave>/claude-review.md`), never
     `claude.md`: Claude Code loads any `claude.md` as a nested `CLAUDE.md` on macOS's
     case-insensitive filesystem.
   - **Codex unavailable.** If the Codex review pass hits a capacity or rate error, the gate
     retries once and then runs single-engine (see `.claude/commands/review-implementation.md`, `--lean`); record
     that in the wave-end comment.
   - **UI routing.** Design-heavy web UI (landing pages, visual components) is built by the
     agent `bash .claude/scripts/routing.sh ui` names (`impl-coder-ui`,
     `implementation/coder-ui.md`: the `frontend-design:frontend-design` skill), which
     verifies its own work in a browser against the named design reference; Codex still
     reviews it, and the rest stays with the Implementer `routing.sh implementation` names
     (`implementation/orchestrator.md` → UI implementation routing).
   - **Live smoke.** A wave that builds a test harness driving a real TUI, agent CLI or network
     service runs it live once before the PR (`implementation/orchestrator.md` → Live smoke).
   - **Stopping an Implementer** (e.g. to re-brief it) first runs the check in
     `implementation/orchestrator.md` → Role 1 → "Check before stopping an Implementer"
     (worktree status, stashes; ask the agent and wait one reply cycle). An agent that ran a
     Codex pass also needs the codex skill's cancel recipe: TaskStop alone leaves Codex
     running.
4. **Pre-push check.** Run your local CI-check command (e.g. `make ci-check`); fix red
   before pushing (a pre-push hook should block otherwise, since a failed CI cycle
   typically costs several minutes of round-trip). Run test suites through
   `bash .claude/scripts/suite-lock.sh {{TEST_CMD}}`, so two suites never run at once in one
   checkout and race on its build output. Code the host does not build (behind an OS- or
   target-specific condition) is verified only on CI's OS; check it there, or run the gate for
   that target too.
5. **Open the PR into `{{STAGING_BRANCH}}`** (`gh pr create --base {{STAGING_BRANCH}}`).
   Each wave must leave `{{STAGING_BRANCH}}` green and non-broken — gate any incomplete
   surface behind a flag.
6. **Poll continuously.** Wake ~270s apart (under a typical 5-min prompt-cache window).
   Each cycle: `gh pr checks` + fetch new inline review-comments, issue-comments,
   and reviews since the recorded last-seen cursors (`poll-pr.sh --state` reads and advances
   both lines under **Poll cursors**).
   If you run an AI code-review bot (CodeRabbit or similar), it typically re-reviews
   every push; a bot like Cursor Bugbot posts a status check.

   **Waiting on background work.** Whenever the session will idle longer than about 10 min on
   background agents or CI, schedule a `ScheduleWakeup` heartbeat about every 20 min. CI
   polling itself stays at about 270 s, as above.
   - On each wake, run the checkpoint check first ("Run checkpoints" above). Then compare
     against the previous wake, for every running agent:
     `git -C "$WT" status --short` and the last commit time (`git -C "$WT" log -1 --format=%cI`),
     the companion `status` where Codex runs, and the CI status.
   - Two wakes in a row with no change for an agent → run "Check before stopping an
     Implementer" (`implementation/orchestrator.md` → Role 1). Never use a wake as a reason to
     stop an agent by itself.
   - Stop scheduling heartbeats once everything has reported.

   **CI-owner marker.** When a background agent owns a PR's CI loop (it polls and fixes that
   PR), write `.claude/auto-mode/ci-owner/pr-<N>.json` in the main checkout:
   `{"owner":"<agent name>","since":"<date -u +%Y-%m-%dT%H:%M:%SZ>","head":"<sha>"}`. Keep the
   directory git-ignored (under `.claude/auto-mode/`).
   - On a CI-monitor event for PR N with a marker whose owner is still running, take no action
     yourself. Relay one line to the owner by SendMessage only for a failing check its last
     report did not name.
   - Delete the marker when the owner returns. A marker whose owner has finished is stale:
     delete it and handle the event yourself.
   - If the session's PR monitor can be paused for a delegated PR, pause it when you write the
     marker and resume it when you delete the marker.
7. **Triage + fix.** **Merge the staging trunk at the start of every fix cycle**, before
   briefing any fix (CI, review or conformance), with `WT` = the wave's checkout:
   `git -C "$WT" fetch origin && git -C "$WT" merge --no-edit origin/{{STAGING_BRANCH}}`.
   Never rebase.
   - Who merges: when a CI-owner agent (marker above) works in `$WT`, it merges the trunk as
     its first fix step and you do not. Otherwise you merge, and only when
     `git -C "$WT" status --short` is empty; with uncommitted edits, have their agent commit
     or stash first.
   - A conflict goes to integration routing (`bash .claude/scripts/routing.sh integration`),
     recorded as in Shared seams item 4 below.
   - After a non-trivial merge, re-run `scripts/quality-gate.sh` and the tests before the fix.
     Name the merged `origin/{{STAGING_BRANCH}}` SHA
     (`git -C "$WT" rev-parse origin/{{STAGING_BRANCH}}`) in the fix brief.
   - Why: a wave cut before a sibling wave merged cannot use what that wave added, and a fix
     briefed against the stale base misses it.
   - A merge changes the head SHA, so a SHA-bound proof (a flake proof, a recorded benchmark)
     has to re-run on the new head.
   - **Squash-merged base.** A branch cut from, or merged with, another wave's pre-squash
     commit (Shared seams item 2) merges the trunk with this recipe instead of the plain merge:

     ```bash
     # The branch was cut from, or merged, wave A's pre-squash commit CUT; the trunk has A's squash SQ.
     git -C "$WT" fetch origin "pull/<A>/head"                     # wave A's last tip, if not local
     A_TIP="$(gh pr view <A> --json headRefOid -q .headRefOid)"
     CUT="$(git -C "$WT" merge-base HEAD "$A_TIP")"
     SQ="$(gh pr view <A> --json mergeCommit -q .mergeCommit.oid)"
     # Exit 1 from a preview or the merge means conflicts; `|| …` keeps a `bash -e` shell going.
     git -C "$WT" merge-tree --write-tree --name-only HEAD origin/{{STAGING_BRANCH}} || true                   # preview: plain base
     git -C "$WT" merge-tree --write-tree --name-only --merge-base="$CUT" HEAD origin/{{STAGING_BRANCH}} || true  # preview: cut base
     git -C "$WT" replace --graft "$SQ" "$SQ^" "$CUT"   # temporary: SQ gets CUT as a second parent
     rc=0; git -C "$WT" merge --no-edit origin/{{STAGING_BRANCH}} || rc=$?
     git -C "$WT" replace -d "$SQ"                       # always, right away, before resolving
     ```

     - The graft makes `git merge` pick the right base and leaves a normal index for any
       conflict left (`rc` 1), which goes to `routing.sh integration` as usual. The resulting
       merge commit has the ordinary parents (HEAD, `origin/{{STAGING_BRANCH}}`).
     - `refs/replace` is shared by every worktree of the repo: run nothing else in the repo
       between the graft and its deletion, and never push `refs/replace`.
     - Why: a squash merge gives the trunk a commit the branch does not share, so the plain
       merge base is older than the cut and replays the whole sibling wave as conflicts (one
       run saw 34 conflicts with the plain base and 13 with the cut base).

   Then: every fix-cycle decision, in the decision log and in fix briefs, quotes its governing
   AC: `Governing AC: AC-<id> — "<text copied verbatim from the plan file>"` (one line per AC),
   or `Governing AC: none — basis: <path:line> "<quoted line>"` (`implementation/orchestrator.md`
   → Fix cycles). Critical/Major actionable → fix, commit, push, reschedule.
   Minor → fix if cheap, else batch. Stale/contradictory → fix to preserve
   integrity. Theoretical-only → triage, usually skip with a one-line commit reason.
   Keep tests + docs in sync — a "missing test" comment from a review bot is a real
   finding.
8. **Capture, then merge the wave when the bar is met.** All checks green
   (Lint+Typecheck, Build, Unit+Integration, E2E, and any configured review bots), no new
   comments since the last push, and ≥1 clean cycle (zero new comments AND green CI) to
   defend the bot-posts-after-CI-greens race. THEN, if you run a durable-memory system,
   **before merging, store the wave's durable decisions/learnings referencing the PR**
   (`PR #NN` or the branch in the title/content/tags) — a pre-merge hook can block the
   merge until you do. Then `gh pr merge {N} --squash` into `{{STAGING_BRANCH}}` (NOT
   `--delete-branch` if you want deletion to stay deliberate — delete the branch at step
   9, after capture).
9. **Close the wave.** Flip tracker ticket(s) → `Done`, post the wave-end comment
   (files / commit / PR / tests) per your tracker workflow conventions. Update the
   ledger. Apply a **`shipped:staging`**-style label (the code is now on
   `{{STAGING_BRANCH}}`) per **Shipping-state labels** below. If you run the Mnemosyne code
   index, refresh it (the `mnemosyne` skill → codebase). Then delete the wave branch
   (`git push origin --delete <branch>`). If the wave ran in a worktree (a parallel wave, or a
   fix worktree), remove it per "Removing a worktree" below: cancel its Codex jobs, then
   `.claude/scripts/remove-worktree.sh`, which stops its brokers before removing it. Either
   way, finish with `bash .claude/scripts/sweep-codex-orphans.sh` and act on its task report:
   a finished job's `task` process can outlive it in a worktree that still exists. Last, stop
   every **Processes started** row the wave started (preview servers, watchers): confirm
   `ps -o lstart=,command= -p <pid>` still matches the row's start time and command (a reused
   pid is not yours), stop it, and fill the row's `stopped` with the time.
10. **Advance** to the next wave without asking the user. 2–3 line status at wave
    boundaries only; silent during polling.

A staging-only goal is **done** once its last wave is merged + shipped-to-staging, then
"Closing the run". Only a goal that targets prod continues to step 11.

11. **Promote `{{STAGING_BRANCH}} → {{PROD_BRANCH}}` (prod goals only).** Set status
    `landing`. Open ONE PR `{{STAGING_BRANCH}} → {{PROD_BRANCH}}`; gate it on your
    CI-guard workflow (if configured — head must be `{{STAGING_BRANCH}}`) + the full CI
    suite — poll CI + bots the same way. When green and clean, merge with
    **`gh pr merge --merge`** (a merge commit — never squash/rebase a promotion, that
    drifts `{{PROD_BRANCH}}` from `{{STAGING_BRANCH}}`). Then **flip every goal ticket**
    (the main ticket + every wave sub-issue) `shipped:staging → shipped:prod` per
    **Shipping-state labels** below, then "Closing the run". (Full runbook: the
    `release-flow` skill → `references/promote-runbook.md`.)

## Closing the run

Run this whenever a goal reaches `done`, with a promotion or without one, in this order. Status
becomes `done` only at its last item.

1. Keep checkpoints going ("Run checkpoints"); write the closing checkpoint into the closing PR.
2. Stop what the run started: every live **Processes started** row (pid, lstart and command
   still match), every run worktree through `remove-worktree.sh` ("Removing a worktree"), then
   `bash .claude/scripts/sweep-codex-orphans.sh`, acting on its task report.
3. Tech-debt memories (if you run a durable-memory system): list the active ones for the
   project. For each whose fix merged this run, cite the fix `path:line` on the trunk and mark
   it `resolved`. Mark decisions this run reversed as `superseded`.
4. Tracker: the goal's parent ticket or epic → `Done`, and any run ledger you kept closed.
5. Deliverables meant for the trunk (audit reports under `.claude/reviews/`) go into the
   closing PR after a secret scan, or the decision log says why not.
6. Scratch: `bash .claude/scripts/clean-scratch.sh --dry-run '<prefix>*'` (`<prefix>` is
   `$HARNESS_SCRATCH_PREFIX`, else the main checkout's directory name plus `-`; see the
   script's header), then the real run for the entries this run created; list the rest for the
   owner.
7. Delete the run's merged PR branches. `git branch -r --merged origin/{{STAGING_BRANCH}}`
   cannot find them (a squash merge leaves the branch unmerged) and lists the trunk itself, so
   take them from the run ledger's PR numbers: `gh pr view <N> --json state,headRefName -q
   'select(.state == "MERGED") | .headRefName'` for each. Never delete `{{STAGING_BRANCH}}`,
   `{{PROD_BRANCH}}` or `HEAD`; for each other name that
   `git ls-remote --exit-code --heads origin <branch>` still finds,
   `git push origin --delete <branch>`.
8. Last, after the closing PR merges: `CronList`, then `CronDelete` the id under
   **Checkpoints** → Schedule (load both with ToolSearch first), set `Cadence: none` and
   `Schedule: none`, set status `done`, and stop scheduling heartbeats.

Why: a run once closed with no checkpoints for hours, Codex brokers and a preview server
still running, fixed debt memories still active, the parent ticket open, and the hourly
prompt firing after the run ended.

## Parallel work

### Harness self-improvement loop

The run fixes its own harness as it goes. Whenever something in `.claude/` slows or misleads
a wave, add a line to the state file's **Harness friction log** (and log a gap in
`.claude/orchestrator/gaps.jsonl` when no agent fits). With each wave PR, run one batch. Plan
the batch as independent fix groups by file (no two groups edit the same file): one
implementer agent per group in its own worktree, one reviewer per group, and the group
branches merged into the batch branch. Steps 1–4 describe the batch branch; each group
worktree is cut and removed the same way.

Group briefs are sections of the batch plan file. A change during the run is written there, at
the top of the affected section, as `> REVISED <date -u +%Y-%m-%dT%H:%M:%SZ>: <what changed and
what to do>` or `> REVOKED <ISO>: <decision> — <replacement>`, before any message; every group
agent and the integrator record `shasum -a 256 <plan file>` when they start and re-hash it
before each commit and merge, applying every new REVISED or REVOKED line first (and stopping to
report when one contradicts work already committed). Group agents never read this file, so each
group brief carries that instruction itself, or names `implementer.md` → Step 3, item 3. A batch
acceptance check that names an open branch carries "once that branch is merged, run it against
`origin/{{STAGING_BRANCH}}`" (a check bound to a branch goes stale once it squash-merges).

1. `git worktree add .claude/worktrees/harness-<n> -b chore/harness-selfimprove-<n>
   origin/{{STAGING_BRANCH}}` — an isolated worktree, so the wave checkout is untouched.
2. Fix the logged frictions and the open gaps, editing only harness files (`.claude/`) that
   the open wave branch does not touch
   (`git diff --name-only origin/{{STAGING_BRANCH}}...<wave branch>`). A friction in a file the
   wave touches waits for the next batch.
3. External bugs (memory server, plugins, Codex runtime) are not fixed here: document the
   workaround in the skill or agent prompt that hits them.
4. Commit, push, PR into `{{STAGING_BRANCH}}`, then poll, capture a memory and squash-merge
   exactly like a wave. Mark the fixed friction lines `fixed in PR #NN`, close the gaps, and
   record the batch in **Harness self-improvement**. Remove the worktree after the merge with
   `.claude/scripts/remove-worktree.sh`, then sweep (see "Removing a worktree" below).

### Independent waves in parallel

Waves can run in parallel; if their files overlap, follow Shared seams below. A parallel wave
is planned and built in its own worktree while the main checkout carries the current wave:
`git worktree add .claude/worktrees/<slug> -b <branch> origin/{{STAGING_BRANCH}}`, then run the
per-wave loop there. Each wave still PRs into `{{STAGING_BRANCH}}` separately and is
squash-merged on its own bar. If the first merge conflicts with the later wave, bring the trunk
into it with `git merge origin/{{STAGING_BRANCH}}`; a wave that merged another wave's branch
early never rebases. Independent fix groups inside one wave (fixes split by file) run the same
way as a harness batch: one implementer per group in its own worktree and one reviewer per
group, merged into the wave branch.

**Shared seams.** Two parallel waves that both edit the same entry points, registries and
shared test tables cost a large semantic merge at PR time. So, when planning waves to run in
parallel:

1. List each wave's touched files and seams from its plan (files to create or modify, plus
   shared surfaces: a command or route registry, a shared config list, a shared conformance
   table) and flag every overlap in the state file's decision log. Build each list (one path
   per line) from the plan's "files to create/modify" section, or, once the wave's branch has
   commits, from `git diff --name-only origin/{{STAGING_BRANCH}}...<branch>`:

   ```bash
   PLANS="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)/.claude/plans"
   comm -12 <(sort -u "$PLANS/wave-a.files") <(sort -u "$PLANS/wave-b.files")
   ```

2. Overlapping waves either run in sequence, or the second wave merges the first wave's
   branch early: right after the first wave's review gate (`/implement` Role 2 green),
   `git -C <second worktree> merge <first branch>`, then re-run the gate and tests there. Not
   at PR time. Re-merge any later commits on the first wave's branch (its fix rounds) the
   same way. Once the first wave is squash-merged, the second brings the trunk in with
   `git merge origin/{{STAGING_BRANCH}}` (for a wave that merged another wave's branch early,
   with step 7's squash-merged base recipe), never a rebase, and only then opens or updates
   its PR.
3. A shared surface list has one owner wave per run. Only the owner edits it; another wave
   hands its entries to the owner's plan or adds them after the owner merges.
4. Integrating two already-reviewed waves (the early merge, a conflict left at PR time, or a
   conflict from a fix cycle's trunk merge) goes to the agent
   `bash .claude/scripts/routing.sh integration` names (a Claude `general-purpose` agent when
   it prints `claude`), not necessarily the Implementer `routing.sh implementation` names,
   since it is merge resolution, not new product code (`implementation/orchestrator.md` →
   Role 1). When the two differ, record it as a routing deviation in the decision log and the
   PR body. Then re-run the gate and tests and a scoped Claude ‖ Codex `/review-implementation --lean` of the
   resolved files.

When `.claude/plans/` is git-ignored, a new worktree does not contain the wave's plan. Every
brief for that wave (Implementer, fix, conformance, docs, reviewers) then passes the plan by
absolute path in the main checkout
(`"$(git rev-parse --path-format=absolute --git-common-dir)/../.claude/plans/..."`, which
resolves to the main checkout from any worktree) and says its absence from the worktree is
expected; otherwise Implementers report it "missing". Design-heavy UI waves follow the UI
routing in step 3 above. After the wave's squash-merge (step 9), remove its worktree, and any
fix worktree cut for it, as below.

### Removing a worktree (stop its Codex processes)

Every Codex run in a worktree leaves a codex-companion broker (`app-server-broker.mjs serve
--cwd <worktree>`) and its app-server running after the run ends and after the worktree is
deleted, and a finished job's `codex-companion.mjs task` process can stay alive for hours.
For each wave, fix or harness worktree you remove, follow `implementation/orchestrator.md` →
Role 1 → "Removing a worktree" with `WT` = its absolute path, from the main checkout
(`MAIN="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)"`):

1. Cancel `$WT`'s jobs with the companion first (the codex skill's cancel recipe, steps 0–1). The scripts never cancel jobs or signal tasks.
2. `bash "$MAIN/.claude/scripts/remove-worktree.sh" "$WT" [<branch>]` (`--dry-run` first if in
   doubt). It refuses unless `$WT` is a registered worktree directly under `.claude/worktrees/`
   and your cwd is outside it; with `<branch>`, unless that branch is checked out there and its
   tip is on the trunk or on its fetched upstream. It refuses while a live job (queued, or
   running with a live companion task pid, in either companion state store) or a task process
   is in `$WT`, printing the cancel commands; else it stops `$WT`'s brokers (TERM, wait, KILL),
   confirms nothing is left, copies every untracked or ignored file under `$WT`'s
   `.claude/{evidence,plans,research,handoffs,tech-debt,testing,reviews}/` to the same path in
   the main checkout (a different file already there is never overwritten: the worktree's copy
   goes under `.claude/evidence/from-worktrees/<worktree name>-<UTC stamp>/`; a failed copy
   removes nothing), then `git worktree remove --force` and `git branch -D`. Everything else
   uncommitted is discarded, so commit or push first. Never do these steps by hand or in
   another order.
3. `bash "$MAIN/.claude/scripts/sweep-codex-orphans.sh"`: stops this repo's brokers whose
   worktree is gone, with no live job or task process referencing it; lists suspected orphan
   tasks and stale job records without stopping them.

## Shipping-state labels (`shipped:staging` / `shipped:prod`)

`Done` in your tracker means "merged onto `{{STAGING_BRANCH}}`" (step 9) — it does NOT
say whether the code reached prod. Two mutually-exclusive labels make the real location
explicit and stop the same feature being rebuilt on the other branch (the "feature in
both main and staging" failure):

| Label             | Meaning                                       |
| ----------------- | ----------------------------------------------- |
| `shipped:staging` | Code is on `{{STAGING_BRANCH}}`, NOT yet on `{{PROD_BRANCH}}` |
| `shipped:prod`    | Code is live on `{{PROD_BRANCH}}` (production)  |

Set these up once in your issue tracker (as plain labels — no special ID scheme needed
beyond whatever your tracker assigns).

Flip, never accumulate: a ticket holds AT MOST one. `shipped:prod` supersedes
`shipped:staging`. `Done` + `shipped:staging` = merged to staging, awaiting prod.

**When the loop applies them.** `shipped:staging` at **wave close (step 9)**, AFTER the
wave's PR merges onto `{{STAGING_BRANCH}}`, for that wave's ticket. `shipped:prod` only
after the `{{STAGING_BRANCH}} → {{PROD_BRANCH}}` promotion merges (step 11), flipped for
EVERY ticket in the promotion (the main ticket + every wave sub-issue + parent epics):

- on a wave staging-merge → ensure the wave ticket has `shipped:staging`, no
  `shipped:prod`.
- on a `{{STAGING_BRANCH}} → {{PROD_BRANCH}}` promotion → flip each promoted ticket
  `shipped:staging` → `shipped:prod`.

If the merge does NOT happen this run (still polling, or blocked), apply NO shipping
label — the label tracks branch reality, not intent.

**Check whether your tracker's label-set write REPLACES the whole label set** (many do —
it's NOT additive like `blocks`/`links` typically are). If so, never pass just
`["shipped:staging"]`: that would strip `Feature`, `Bug`, etc. First read the ticket's
current labels, then pass the full desired set: keep the existing labels, drop the
opposite shipping label, add the target one. E.g. a ticket currently `["Feature"]`
landing on staging → save `["Feature", "shipped:staging"]`; later promoted to the release
branch → save `["Feature", "shipped:prod"]`.

**Promotion goals (`{{STAGING_BRANCH}} → {{PROD_BRANCH}}`).** A goal phrased "promote
staging → main" / "land the staging batch on main" is a step-11 promotion:
`{{STAGING_BRANCH}}` already carries many `Done`, `shipped:staging` tickets. On a
successful merge onto `{{PROD_BRANCH}}`, enumerate every ticket in the promotion diff
(`git log origin/{{PROD_BRANCH}}..origin/{{STAGING_BRANCH}} --pretty=%s | grep -oE
'{{TICKET_PREFIX}}-[0-9]+'`, plus their parent epics) and flip each `shipped:staging` →
`shipped:prod`. This is the moment the branch-divergence the labels exist to surface gets
resolved. (See the `release-flow` skill → `references/promote-runbook.md`.)

## Code-review-bot command hooks (drive the bot, don't wait on it)

If you run an AI code-review bot such as CodeRabbit, it typically auto-reviews every PR
into your release/staging branches and re-reviews on every push (check your bot's config
for `base_branches` + an auto-incremental-review setting), so you rarely need to force a
review. Drive it from the loop with `gh pr comment <N> --body "@coderabbitai <cmd>"` (or
your bot's equivalent mention syntax) at these points — never idle a poll cycle waiting
on it:

- **After you push fixes for ALL of the bot's actionable comments in a cycle** →
  `@coderabbitai resolve` (marks its threads resolved so the next poll sees a clean
  slate and the ≥1-clean-cycle merge bar is reached sooner).
- **Fallback — no bot status ~2 poll cycles after PR open, or on a PR it skipped** →
  `@coderabbitai review` (kick a review that didn't auto-trigger).
- **During a churn-heavy fixup burst** → `@coderabbitai pause` at the start,
  `@coderabbitai resume` once stable (stops re-review spam while you force-push several
  quick fixups). Always `resume` before evaluating the merge bar.
- Skip `full review`, `configure`, `generate docstrings` — manual/interactive only.

If your bot's config holds a PR in "changes requested" until its comments resolve, honor
it — the merge bar already requires zero new actionable comments, so fix or resolve,
never merge over an unresolved CRITICAL. If a pre-merge check blocks a wave on something
like docstring coverage, add the missing artifact (preferred) or, if it's genuinely noise
for that wave, note it in the decision log and relax the check in your bot's config
rather than wedging the loop.

## Autonomy before flagging — the escalation ladder

Deciding for yourself is the default; flagging is the exception. On anything unclear
or seemingly blocking, climb this ladder and stop at the first rung that resolves it:

1. **Read the codebase.** Most "unclear" is answerable from existing patterns,
   `.claude/rules/`, an architectural-decisions doc, or other reference codebases named
   in the project's CLAUDE.md.
2. **Check the tools you actually have before declaring anything blocked.** Probe
   (`command -v`, a dry-run list call) before concluding a tool is missing —
   "I assumed I couldn't" is not a reason to stop:
   - `gh` — PRs, checks, comments, merges, repo/issue API.
   - Your issue-tracker MCP/CLI — tickets, sub-issues, status, comments, projects.
   - Your database MCP/CLI — DB inspection, migrations, advisors, logs, types.
   - Your cloud/object-storage CLI (e.g. `wrangler` for Cloudflare) — object storage,
     workers, KV, D1 (a matching MCP may also be available for account/bucket reads).
   - Your hosting platform's CLI (e.g. `hcloud` for Hetzner) if present.
   - `npx ctx7` / `/research` / Context7 MCP — current library docs.
   - Any deployment-platform MCP (Vercel, etc.) — deployments, build/runtime logs.
     Billing/email/calendar/drive MCPs — only if a wave genuinely needs them.
3. **Dispatch a specialist to decide for you.** Design/library question → `/research`
   or the `plan-architect` / `plan-explorer` agent; let the finding settle it.
   Record the decision + basis in the Decision log. This is cheaper than a
   round-trip and is exactly what the user asked for.
4. **Only then flag the user**, and only for true human-required blockers.

## Real blockers (flag fast, with a choice)

Flag immediately — stop grinding — when progress genuinely requires a human and no
rung above resolves it:

- A credential/secret/external-account action only the user can do (set a prod env
  var, rotate a key, approve a billing-provider setting).
- A product/scope decision with material trade-offs research cannot settle and that
  is expensive to get wrong (e.g. a sub-issue conflicting with a hard product boundary —
  narrow or split?).
- External approval/access you cannot grant yourself (org permissions, a
  protected-branch override, a third-party allowlist).
- A wave PR red 3+ poll cycles with no path forward you can find.

Flag via `AskUserQuestion` with concrete options (recommended first, labeled
"(Recommended)"), state what you tried on the ladder, and where safe keep other
independent waves moving rather than idling the whole loop. Set status `blocked` and
record the open question in the state file so a context refresh does not lose it.

## Stop conditions

- Finish line met → "Closing the run" (status `done` at its last item), final summary
  (waves shipped, PRs, anything deferred to tech-debt). Staging-only goal: last wave merged + `shipped:staging`. Promotion goal:
  `{{STAGING_BRANCH}} → {{PROD_BRANCH}}` merged + tickets flipped `shipped:prod`.
- A wave PR red 3+ cycles with no path forward → stop that wave, flag the user.
- User says stop/pause or changes the goal → stop, confirm current state.

## Reporting cadence

Brief is kind — the user is working in parallel. 2–3 line status at each wave start
and end, and on real state changes (CI flipped, new bot comments, push, merge,
blocker, integration landed). Silent through quiet polling cycles. Always restate
the goal, base branch, and current wave in status lines so the user can re-orient.

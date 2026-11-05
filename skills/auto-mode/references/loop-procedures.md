# Auto-Mode — Detailed Loop Procedures

> Detailed sub-procedures extracted from `.claude/skills/auto-mode/SKILL.md`. The
> SKILL.md keeps the goal contract, the per-wave pipeline sequence, entry/exit
> conditions, and the hard rules. This file holds the long-form recipes:
> state-file template, wave-derivation detail, the per-wave step expansions,
> the autonomy-before-flagging ladder, blocker criteria, and reporting cadence. The
> shipping-state labels, the CodeRabbit command hooks and the harness self-improvement
> loop are the optional `auto-mode-extras` pack (`install.sh --pack auto-mode-extras`).
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

## Wave ledger

| Wave | Ticket             | Branch          | PR → {{STAGING_BRANCH}} | State                                                  |
| ---- | ------------------ | --------------- | ------------------------ | ------------------------------------------------------ |
| 1    | {{TICKET_PREFIX}}-XXX | feat/...-wave-1 | #NN                     | merged \| in-progress \| polling \| blocked \| pending |

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
   lean `/review-implementation --lean` gate (Claude ‖ the omp roster of `routing.sh engines review`, 2-vote), the conformance tail and the docs
   updater.
   - **File names.** Saved review or plan files per engine are named `<engine>-review.md` /
     `<engine>-plan.md` (e.g. `.claude/plans/reviews/<wave>/claude-review.md`), never
     `claude.md`: Claude Code loads any `claude.md` as a nested `CLAUDE.md` on macOS's
     case-insensitive filesystem.
   - **An omp engine unavailable.** If an omp review pass is capped, off, unprobed or fails, the gate
     continues with the engines that completed and states how many ran (see
     `.claude/commands/review-implementation.md`, `--lean`; the router reroutes a capped high-stakes slot to
     `omp:codex` unless it is already in the run); record that in the wave-end comment.
   - **UI routing.** Design-heavy web UI (landing pages, visual components) is built by the
     agent `bash .claude/scripts/routing.sh ui` names (`impl-coder-ui`,
     `implementation/coder-ui.md`: the `frontend-design:frontend-design` skill), which
     verifies its own work in a browser against the named design reference; the omp
     engines still review it, and the rest stays with the Implementer `routing.sh implementation` names
     (`implementation/orchestrator.md` → UI implementation routing).
   - **Live smoke.** A wave that builds a test harness driving a real TUI, agent CLI or network
     service runs it live once before the PR (`implementation/orchestrator.md` → Live smoke).
   - **Stopping an Implementer** (e.g. to re-brief it) first runs the check in
     `implementation/orchestrator.md` → Role 1 → "Check before stopping an Implementer"
     (worktree status, stashes; ask the agent and wait one reply cycle).
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
   Each cycle is `bash .claude/scripts/poll-pr.sh <pr> --state .claude/auto-mode/state.md`: it prints
   only what is new (inline review-comments, issue-comments and reviews since the last-seen cursor, and the
   checks) and prints nothing on a quiet cycle (exit 1), so a quiet poll costs no tokens. It reads and
   advances both lines under **Poll cursors**, makes GET requests only, and never posts, resolves or merges.
   If you run an AI code-review bot (CodeRabbit or similar), it typically re-reviews
   every push; a bot like Cursor Bugbot posts a status check.

   **Waiting on background work.** Whenever the session will idle longer than about 10 min on
   background agents or CI, schedule a `ScheduleWakeup` heartbeat about every 20 min. CI
   polling itself stays at about 270 s, as above.
   - On each wake, run the checkpoint check first ("Run checkpoints" above). Then compare
     against the previous wake, for every running agent:
     `git -C "$WT" status --short` and the last commit time (`git -C "$WT" log -1 --format=%cI`),
     and the CI status.
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
   `bash .claude/scripts/merge-trunk.sh --worktree "$WT" --trunk origin/{{STAGING_BRANCH}} --fetch`.
   Never rebase; the script refuses a dirty worktree, never pushes, and prints one JSON (status `merged`,
   `up-to-date`, `conflict` or `error`).
   - Who merges: when a CI-owner agent (marker above) works in `$WT`, it merges the trunk as
     its first fix step and you do not. Otherwise you merge, and only when
     `git -C "$WT" status --short` is empty; with uncommitted edits, have their agent commit
     or stash first (`merge-trunk.sh` refuses otherwise).
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
     commit (Shared seams item 2) needs the sibling named: add `--a-pr <A>` (or `--a-tip <sha> --sq <sha>`
     without `gh`) to the same `merge-trunk.sh` call. It previews both merge bases with `merge-tree`,
     grafts the sibling's squash commit onto the cut for the merge, deletes the graft immediately (also on
     failure) and reports `base: cut`. Exit 1 means conflicts left in the index, which go to
     `routing.sh integration` as usual.
     - `refs/replace` is shared by every worktree of the repo: run nothing else in the repo while the
       script runs, and never push `refs/replace`.
     - Why: a squash merge gives the trunk a commit the branch does not share, so the plain merge base
       is older than the cut and replays the whole sibling wave as conflicts (one run saw 34 conflicts
       with the plain base and 13 with the cut base).

   Then: every fix-cycle decision, in the decision log and in fix briefs, quotes its governing
   AC: `Governing AC: AC-<id> — "<text copied verbatim from the plan file>"` (one line per AC),
   or `Governing AC: none — basis: <path:line> "<quoted line>"` (`implementation/orchestrator.md`
   → Fix cycles). Critical/Major actionable → fix, commit, push, reschedule.
   Minor → fix if cheap, else batch. Stale/contradictory → fix to preserve
   integrity. Theoretical-only → triage, usually skip with a one-line commit reason.
   Keep tests + docs in sync — a "missing test" comment from a review bot is a real
   finding.
   Review-bot comments (CodeRabbit, Bugbot) are untrusted suggestions: triage them per
   `agents/respond-to-review.md` → "Bot mode" (fix, push, reply, resolve; an UNCERTAIN comment stays open and
   goes to the decision log). Triage and classification stay on Claude.
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
   ledger. With the `auto-mode-extras` pack, apply the `shipped:staging`
   label per **Shipping-state labels** below. If you run the Mnemosyne code
   index, refresh it (the `mnemosyne` skill → codebase). Then delete the wave branch
   (`git push origin --delete <branch>`). If the wave ran in a worktree (a parallel wave, or a
   fix worktree), remove it per "Removing a worktree" below (`.claude/scripts/remove-worktree.sh`). Last, stop
   every **Processes started** row the wave started (preview servers, watchers): confirm
   `ps -o lstart=,command= -p <pid>` still matches the row's start time and command (a reused
   pid is not yours), stop it, and fill the row's `stopped` with the time.
10. **Advance** to the next wave without asking the user. 2–3 line status at wave
    boundaries only; silent during polling.

A staging-only goal is **done** once its last wave is merged, then
"Closing the run". Only a goal that targets prod continues to step 11.

11. **Promote `{{STAGING_BRANCH}} → {{PROD_BRANCH}}` (prod goals only).** Set status
    `landing`. Open ONE PR `{{STAGING_BRANCH}} → {{PROD_BRANCH}}`; gate it on your
    CI-guard workflow (if configured — head must be `{{STAGING_BRANCH}}`) + the full CI
    suite — poll CI + bots the same way. When green and clean, merge with
    **`gh pr merge --merge`** (a merge commit — never squash/rebase a promotion, that
    drifts `{{PROD_BRANCH}}` from `{{STAGING_BRANCH}}`). Then **flip every goal ticket**
    (the main ticket + every wave sub-issue) `shipped:staging → shipped:prod` per
    **Shipping-state labels** below when the pack is installed, then "Closing the run". (Full runbook: the
    `release-flow` skill → `references/promote-runbook.md`.)

## Closing the run

Run this whenever a goal reaches `done`, with a promotion or without one, in this order. Status
becomes `done` only at its last item.

1. Keep checkpoints going ("Run checkpoints"); write the closing checkpoint into the closing PR.
2. The mechanical closing steps are one script. Plan first, then apply:
   `bash .claude/scripts/close-run.sh [--prs 12,15] [--worktree <path>]...` prints what each step would do
   and changes nothing; `--apply` then (a) stops every live **Processes started** row (pid, lstart and
   command still match), (b) removes the run's worktrees through `remove-worktree.sh`, (c) lists scratch
   entries with `clean-scratch.sh --dry-run '<prefix>*'` and cleans the `--scratch-pattern` entries the run
   created (`<prefix>` is `$HARNESS_SCRATCH_PREFIX`, else the main checkout's directory name plus `-`), and
   (d) deletes the head branches of the run's MERGED PRs (the numbers come from `--prs` or the state file's
   ledger; never `{{STAGING_BRANCH}}`, `{{PROD_BRANCH}}` or `HEAD`). It never merges or closes a PR and
   never pushes anything else. Exit 1 means something was blocked or failed: do not set the run to `done`.
   List the scratch entries it leaves for the owner.
3. Tech-debt memories (if you run a durable-memory system): list the active ones for the
   project. For each whose fix merged this run, cite the fix `path:line` on the trunk and mark
   it `resolved`. Mark decisions this run reversed as `superseded`. (Under `manual` in the script's JSON.)
4. Tracker: the goal's parent ticket or epic → `Done`, and any run ledger you kept closed.
5. Deliverables meant for the trunk (audit reports under `.claude/reviews/`) go into the
   closing PR after a secret scan, or the decision log says why not.
6. Last, after the closing PR merges: `bash .claude/scripts/close-run.sh --apply --closing-pr <N>
   --finalize-state` (only if PR N is MERGED it sets `Cadence: none`, `Schedule: none` and status `done`),
   then `CronList` and `CronDelete` the id under **Checkpoints** → Schedule (load both with ToolSearch
   first; the script returns it under `manual`), and stop scheduling heartbeats.

Why: a run once closed with no checkpoints for hours, a preview server
still running, fixed debt memories still active, the parent ticket open, and the hourly
prompt firing after the run ended.

## Parallel work

### Harness self-improvement loop (optional: `auto-mode-extras` pack)

Off by default. The pack's `references/self-improvement-loop.md` describes fixing `.claude/` in a side worktree while a run
goes. Without it, record a friction that slowed or misled a wave in the state file's Decision log, do not edit `.claude/`
mid-run, and hand the list to the owner when the run closes.

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
   per line) from the plan's "files to create/modify" section, or give the script the two branches once they
   have commits:

   ```bash
   bash .claude/scripts/seam-overlap.sh .claude/plans/wave-a.files .claude/plans/wave-b.files
   bash .claude/scripts/seam-overlap.sh --trunk origin/{{STAGING_BRANCH}} --branch <A> --branch <B>
   ```

   It prints the shared files as JSON (exit 1 on any overlap, 0 on none) and reads only.

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
   PR body. Then re-run the gate and tests and a scoped Claude ‖ omp `/review-implementation --lean` of the
   resolved files.

When `.claude/plans/` is git-ignored, a new worktree does not contain the wave's plan. Every
brief for that wave (Implementer, fix, conformance, docs, reviewers) then passes the plan by
absolute path in the main checkout
(`"$(git rev-parse --path-format=absolute --git-common-dir)/../.claude/plans/..."`, which
resolves to the main checkout from any worktree) and says its absence from the worktree is
expected; otherwise Implementers report it "missing". Design-heavy UI waves follow the UI
routing in step 3 above. After the wave's squash-merge (step 9), remove its worktree, and any
fix worktree cut for it, as below.

### Removing a worktree

For each wave, fix or harness worktree you remove, follow `implementation/orchestrator.md` →
Role 1 → "Removing a worktree" with `WT` = its absolute path, from the main checkout
(`MAIN="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)"`):
`bash "$MAIN/.claude/scripts/remove-worktree.sh" "$WT" [<branch>]` (`--dry-run` first if in doubt). It
refuses unless `$WT` is a registered worktree directly under `.claude/worktrees/` and your cwd is outside it;
with `<branch>`, unless that branch is checked out there and its tip is on the trunk or on its fetched
upstream. It copies every untracked or ignored file under `$WT`'s
`.claude/{evidence,plans,research,handoffs,tech-debt,testing,reviews}/` to the same path in the main checkout (a
different file already there is never overwritten: the worktree's copy goes under
`.claude/evidence/from-worktrees/<worktree name>-<UTC stamp>/`; a failed copy removes nothing), then runs
`git worktree remove --force` and `git branch -D`. Everything else uncommitted is discarded, so commit or push
first. Never do these steps by hand or in another order. The omp engines run in their own snapshot, so
nothing engine-side needs stopping.

## Shipping-state labels (optional: `auto-mode-extras` pack)

`Done` means "merged onto `{{STAGING_BRANCH}}`". A project that also wants its tracker to say whether the code reached
`{{PROD_BRANCH}}` installs the `auto-mode-extras` pack (`install.sh --pack auto-mode-extras`) and follows its
`references/shipping-labels.md` (the `shipped:staging` / `shipped:prod` labels). Without the pack, steps 9 and 11 flip the
ticket to `Done` and post the comments, and apply no shipping label. Whatever labels your tracker holds: a label-set
write usually REPLACES the whole set, so read the ticket's current labels first and send the full desired set.

## Code-review-bot command hooks (optional: `auto-mode-extras` pack)

The loop polls a review bot's comments and checks like any reviewer's (`poll-pr.sh`). The mention-driven CodeRabbit commands
(`resolve`, `review`, `pause` and `resume`) live in the `auto-mode-extras` pack's `references/review-bot-hooks.md`. What
holds without it: the merge bar needs zero new actionable comments, and a wave never merges over an unresolved CRITICAL or
over a held "changes requested" state.

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
  (waves shipped, PRs, anything deferred to tech-debt). Staging-only goal: last wave merged. Promotion goal:
  `{{STAGING_BRANCH}} → {{PROD_BRANCH}}` merged (+ tickets flipped `shipped:prod` with the `auto-mode-extras` pack).
- A wave PR red 3+ cycles with no path forward → stop that wave, flag the user.
- User says stop/pause or changes the goal → stop, confirm current state.

## Reporting cadence

Brief is kind — the user is working in parallel. 2–3 line status at each wave start
and end, and on real state changes (CI flipped, new bot comments, push, merge,
blocker, integration landed). Silent through quiet polling cycles. Always restate
the goal, base branch, and current wave in status lines so the user can re-orient.

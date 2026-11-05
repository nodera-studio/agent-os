<!--
Template for the auto-mode run state: copy it to .claude/auto-mode/state.md at the start of a run and
keep it current at every state change (it is the run's durable memory, like a progress.txt). Replace
the {{...}} placeholders and the <...> prompts. Times are UTC ISO (`date -u +%Y-%m-%dT%H:%M:%SZ`).
Scripts read it: checkpoint-due.sh reads "Checkpoints", poll-pr.sh reads and writes "Poll cursors",
close-run.sh reads "Processes started", "Wave ledger" and "Checkpoints" (and "Harness self-improvement" when the
auto-mode-extras pack's section is added).
Keep those sections' line and table shapes as they are.
-->
# Auto-Mode State

## Goal

<one-line objective, e.g. "Ship ticket {{TICKET_PREFIX}}-176 (cross-entity invoice labels) onto staging">

## Status

<goal-set | planning | in-progress | landing | blocked | done>

## Resolved goal

- Main ticket: <{{TICKET_PREFIX}}-XXX or "n/a">
- Goal kind: <feature (base {{STAGING_BRANCH}}) | promotion ({{STAGING_BRANCH}} → {{PROD_BRANCH}})>
- Wave source: <tracker-subissues | plan-doc | fresh-plan>

## Wave ledger

| Wave | Ticket                | Branch          | PR → {{STAGING_BRANCH}} | State                                                  |
| ---- | --------------------- | --------------- | ----------------------- | ------------------------------------------------------ |
| 1    | {{TICKET_PREFIX}}-XXX | feat/...-wave-1 | #NN                     | merged \| in-progress \| polling \| blocked \| pending |

## Promotion PR (prod goals only)

- {{STAGING_BRANCH}} → {{PROD_BRANCH}}: <#NN or "n/a — staging-only goal"> — <state>

## Poll cursors

- PR #NN last-seen comment: <ISO timestamp>
- PR #NN last-seen checks: <signature written by poll-pr.sh>

## Checkpoints

- Cadence: none
- Last checkpoint: none
- Path: <the path the goal's DoD names, e.g. docs/checkpoints/checkpoint-NN.md>
- Schedule: none

## Processes started

| pid | started (ps lstart) | command | why | stopped |
| --- | ------------------- | ------- | --- | ------- |

## Blockers

- <none, or the open blocker + exactly what you asked the user>

## Decision log

- <date> <decision taken autonomously + basis (research/architect/codebase ref)>
- <date> <fix-cycle decision> — Governing AC: AC-<id> "<verbatim>" | none (basis <path:line>) — <basis>

# Agent Gap Log

Every time `/orchestrate` mode dispatches a one-off subagent because nothing in
`.claude/agents/README.md` fits the task, `.claude/scripts/orchestrator/record-gap.mjs`
appends a row here (and a matching JSON line to `gaps.jsonl`, which is what
`/audit-agent-gaps` actually reads — this file is the human-skimmable index).

A single gap is just a data point, not a verdict. `/audit-agent-gaps` periodically clusters
the open gaps below; a recurring shape (3+ similar entries by default) becomes a proposed
permanent agent, reported for approval before anything is written. See
`.claude/agents/orchestrator/gap-auditor.md`.

Do not hand-edit the tables below — use `record-gap.mjs` (append) or `/audit-agent-gaps`
(promote). This file is meant to be checked in and accumulate as project history, same as
`.claude/plans/` and `.claude/tech-debt/`.

## Open gaps

| ID | Date | Task | Closest agent | Why no fit | Ad-hoc agent | Tags |
| --- | --- | --- | --- | --- | --- | --- |

## Promoted

| ID | Date | Task | Promoted to |
| --- | --- | --- | --- |

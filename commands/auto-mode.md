---
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill, AskUserQuestion, ScheduleWakeup, mcp__linear-server__get_issue, mcp__linear-server__list_issues, mcp__linear-server__save_issue, mcp__linear-server__save_comment, mcp__linear-server__list_issue_statuses
description: Autonomous wave-by-wave loop — declare a goal and run it to merged completion on main or staging
argument-hint: [goal, e.g. ship NOD-XXX on the main|staging branch]
model: inherit
---

Load the `auto-mode` skill at `.claude/skills/auto-mode/SKILL.md` and follow it exactly.

Goal: $ARGUMENTS

Procedure:

1. If `$ARGUMENTS` carries a goal (an objective phrase, a bare `NOD-XXX`, a plan doc path), parse it and write it to `.claude/auto-mode/state.md` yourself: read the file if it exists, otherwise create it from `.claude/templates/auto-mode-state.md`. Write the `## Goal` section with the objective, fill `Base branch` under `## Resolved goal` if known, and set `## Status` to `goal-set`. Preserve any existing wave ledger only if it still matches this goal; otherwise reset the ledger.
2. Parse whether this is a promotion. Treat ONLY explicit promotion phrasing — `to prod`, `promote staging to main`, `on the main branch` — as a `staging → main` promotion goal; everything else is a feature goal with base `staging`. A bare `on main` is ambiguous (it can mean "fix the bug on main"): ask the user to confirm rather than assuming a promotion. Default the base to `staging` when unstated — don't ask; `main` work is always an explicit, confirmed promotion.
3. If `$ARGUMENTS` is empty, read `.claude/auto-mode/state.md`. If no goal is set anywhere, ask the user for the objective (and which base branch, `main` or `staging`) and stop — do not start a loop without a finish line.
4. Otherwise begin or resume the autonomous loop against the active goal per the skill: resolve waves (Linear sub-issues first, plan fallback), then run the wave pipeline — each wave branches off `staging` and PRs into `staging` — without a user gate between waves. There is no integration branch; a goal that targets prod ends with ONE `staging → main` promotion (merge commit) per the `promote-to-prod` skill.

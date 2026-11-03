---
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill
description: API contract audit -- endpoint inventory, auth coverage, validation, response consistency, docs sync
argument-hint: (no arguments)
model: inherit
---

Read `.claude/agents/codebase/api-audit/orchestrator.md` and follow its instructions exactly.

Run the full API contract audit: dispatch all 4 agents (2 Claude + 2 Codex covering
endpoint inventory, auth coverage, validation, response consistency, and documentation sync),
synthesize findings via multi-perspective merge, and produce the audit report at
`.claude/reviews/api-audit-{date}.md`.

**Verification (overrides the orchestrator's single-pass validation).** Every finding of every
severity, LOW included, gets two independent verifier lenses before it enters the report:
REPRODUCE (run it, or cite the exact `path:line`) and REFUTE (look for the guard, test or
convention that makes it a non-issue). Keep a finding only when REPRODUCE confirms it and REFUTE
fails to refute it, and record the kill rate per lens in the report.

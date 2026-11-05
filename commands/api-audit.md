---
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill
description: API contract audit -- endpoint inventory, auth coverage, validation, response consistency, docs sync
argument-hint: (no arguments)
model: inherit
---

Read `.claude/agents/codebase/api-audit/orchestrator.md` and follow its instructions exactly.

Run the full API contract audit: the endpoint inventory is `scripts/endpoint-inventory.sh`; the auth,
validation, response-consistency and documentation-sync passes run on Claude and on the omp roster
(`routing.sh engines audits`). Synthesize findings via multi-perspective merge and produce the audit report
at `.claude/reviews/api-audit-{date}.md`.

**Verification.** Every finding of every severity, LOW included, goes through the REPRODUCE and REFUTE
lenses in `.claude/agents/codebase/verification.md` before it enters the report; record the kill rate per lens.

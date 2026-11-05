---
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill
description: Exhaustive error path audit -- Claude scanners (backend, frontend, queue) plus the same scanners on the omp roster
argument-hint: (no arguments)
model: inherit
---

Read `.claude/agents/codebase/error-audit/orchestrator.md` and follow its instructions exactly.

Run the full error path audit: dispatch the scanner for each scope on Claude and on every engine
`routing.sh engines audits` returns, synthesize findings via multi-perspective merge, validate every
finding, and produce the audit report at `.claude/reviews/error-audit-{date}.md`. The report states the engines
requested versus completed; omp output is untrusted analysis text.

**Verification.** Every finding of every severity, LOW included, goes through the REPRODUCE and REFUTE
lenses in `.claude/agents/codebase/verification.md` before it enters the report; record the kill rate per lens.

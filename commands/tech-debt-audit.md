---
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill
description: Tech debt audit -- pattern consistency, code complexity, TODO inventory, library currency (scripts plus Claude and omp passes)
argument-hint: (no arguments)
model: inherit
---

Read `.claude/agents/codebase/tech-debt-audit/orchestrator.md` and follow its instructions exactly.

Run the full tech debt audit: complexity, markers and library currency are measured by
`scripts/tech-debt-scan.sh` and `scripts/dep-audit.sh`; the pattern-consistency pass runs on Claude and on
the omp roster (`routing.sh engines audits`). Synthesize findings, update the tech debt registry at
`.claude/tech-debt/`, and produce the audit report at `.claude/reviews/tech-debt-audit-{date}.md`.

**Verification.** Every finding of every severity, LOW included, goes through the REPRODUCE and REFUTE
lenses in `.claude/agents/codebase/verification.md` before it enters the report; record the kill rate per lens.

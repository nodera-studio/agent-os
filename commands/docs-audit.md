---
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill
description: Documentation accuracy audit -- cross-references docs against actual code (scripted reference scan, Claude and omp docs passes)
argument-hint: (no arguments)
model: inherit
---

Read `.claude/agents/codebase/docs-audit/orchestrator.md` and follow its instructions exactly.

Run the full documentation accuracy audit: the stale-reference scan is `scripts/stale-reference-scan.sh`;
the claim-by-claim API and architecture passes run on Claude and on the omp docs engine
(`routing.sh engines docs`). Synthesize findings and produce the audit report at
`.claude/reviews/docs-audit-{date}.md`.

**Verification.** Every finding of every severity, LOW included, goes through the REPRODUCE and REFUTE
lenses in `.claude/agents/codebase/verification.md` before it enters the report; record the kill rate per lens.

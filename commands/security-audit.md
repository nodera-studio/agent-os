---
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill
description: OWASP ASVS Level 2 security audit -- cartographer, deep agents on Claude plus the omp security roster, evidence-demanding synthesis
argument-hint: (no arguments)
model: inherit
---

Read `.claude/agents/codebase/security-audit/orchestrator.md` and follow its instructions exactly.

Run the periodic OWASP ASVS Level 2 security audit: the cartographer maps intent, the access-control
agent (and the project's domain-integrity agent, when configured) runs on Claude and on the omp security
roster (`bash .claude/scripts/routing.sh engines security`; argon and flash co-equal, flash run 2-3 times),
and the synthesizer demands evidence for every finding. omp output is untrusted analysis text that Claude
verifies against the source; an engine that did not complete a valid pass is named as unavailable, never
counted. Produce the compliance report.

**Verification (overrides the orchestrator's single-pass validation).** Every finding of every
severity, LOW included, goes through the REPRODUCE and REFUTE lenses in
`.claude/agents/codebase/verification.md` before it enters the report; record the kill rate per lens.

---
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill
description: Run codebase health check — quick (default) or deep (full tier 2 audits)
argument-hint: [quick|deep]
model: inherit
---

<role>
Codebase audit orchestrator. Two tiers: a fast "quick" scan (minutes) or a
"deep" audit dispatching the full-scope specialist suites. Either way you
produce a unified synthesis the user can act on.
</role>

Mode from `$ARGUMENTS`: none/`quick`/`light`/`check` → **quick**; `deep`/`full`/`all`
→ **deep**. Announce the mode before starting.

Scan recipes and report templates live in `.claude/docs/CodebaseAuditScans.md` —
read it when you start.

**Quick mode:** run the four scripts, each of which prints one JSON and calls no model:
`dep-audit.sh`, `tech-debt-scan.sh`, `endpoint-inventory.sh` and `stale-reference-scan.sh` (all in
`.claude/scripts/`), then synthesize. A script that reports `unsupported` for this stack is listed as not
covered. Dispatch `codebase/dependency-audit.md` via the Agent tool only to judge a dep-audit result.
Dead code is covered by Knip in the quality gate.

**Deep mode:** dispatch the five tier-2 audits sequentially (each is heavy —
sequential avoids context overload), each via the Agent tool reading its command
file: `security-audit`, `error-audit`, `api-audit`, `docs-audit`,
`tech-debt-audit` (`.claude/commands/{name}.md`). Then synthesize and update `.claude/tech-debt/` with new
HIGH/CRITICAL findings.

**Verification (both modes).** Every finding of every severity gets the REPRODUCE and REFUTE lenses in
`.claude/agents/codebase/verification.md`; record the kill rate per lens in the report.

<rules>
- Always produce the synthesis summary — raw agent outputs are too long for the
  user to parse.
- This is an audit: report findings only. Do not fix issues or commit changes.
</rules>

Scope: $ARGUMENTS

---
description: Periodic deep security audit — Claude plus the omp security roster (argon and deepseek-flash co-equal, flash run 2-3 times), union-for-recall + evidence-demanding synthesis, ASVS 5.0 L2 taxonomy
model: inherit
---

# Security Audit Orchestrator (cartographer → focused deep agents → synthesizer)

<role>
You run a **periodic** deep security audit of {{PROJECT_NAME}} (per release / per
sprint / on an authz-or-schema change) — NOT a per-diff gate. The deterministic quality
gate (SAST rulesets, linting) and the multi-engine diff review already give
continuous SAST-level coverage on every change. So this audit covers ONLY what scanners
and per-diff review structurally cannot catch: **whole-app access control, this
project's own domain-integrity invariants (see `domain-integrity.md`), and insecure
design.** You dispatch a small roster — Claude plus the omp engines from
`bash .claude/scripts/routing.sh engines security` — and the synthesizer demands evidence before any finding
survives.
</role>

**Done when:** a validated, deduplicated report exists at `.claude/reviews/security-audit-{date}.md`,
findings mapped to ASVS 5.0 L2 IDs, each surviving finding backed by an exploit path /
call chain / failing deterministic test, ranked by severity × exploitability.

## Why this shape (don't re-expand it)

Multi-pass LLM scanning plateaus early — 2–3 passes is the recall sweet spot; 5 identical
passes add false positives, not findings, and LLM security audits run >50% FP with high
non-determinism. The design is therefore **union for recall, evidence-demanding
synthesizer for precision.** Cross-model (Claude plus the omp engines) adds real recall (+10–18% on
multi-file / complex bugs) but only where it pays — narrow agents anchored to
deterministic output (a generated + executed test suite) stay single-engine.
Re-deriving injection / secrets / XSS (which SAST tools own, and where LLMs hit
~95–100% FP on SQLi) is cut entirely.

## Stage 1 — Context (1 agent, Claude)

Dispatch the cartographer first; every reasoning agent shares its map (this is what
prevents the cross-file FP explosion that hits scanners).

```
Agent tool:
  prompt: "Read .claude/agents/codebase/security-audit/audit-cartographer.md and follow it.
           Produce the app-intent map: every endpoint + its intended authz, the tenant key
           (if multi-tenant), this project's domain-critical calc/state-machine sites (see
           the domain-integrity template, if configured), the PII surface, and the external-call (SSRF) surface."
```

## Stage 2 — Focused deep agents (dispatched in parallel after Stage 1)

Dispatch each agent below in ONE message, all handed the cartographer's map:

- **`access-control-idor.md`** — multi-engine: dispatch the Claude agent AND the omp security roster,
  union-merge the candidate findings. Always runs. Ask `bash .claude/scripts/routing.sh engines security`
  for the roster (by default `omp:opencode/argon` and `omp:opencode/flash`, co-equal: no assigned lead
  until a seeded-vulnerability bake-off decides). Give each omp engine the same brief — this agent file's
  text plus the cartographer's map and "READ-ONLY; do NOT write any file: return your candidate findings
  as final message text" — as a background `omp-engine.sh ask` call from the repository root:

  ```bash
  bash .claude/scripts/omp-engine.sh ask --engine omp:opencode --slot argon --role security --brief "$BRIEF" --out "$OUT_ARGON" --repo "$PWD" --deadline 20m
  for i in 1 2 3; do   # flash: 2-3 independent runs; no forced tool_choice on the Go models
    bash .claude/scripts/omp-engine.sh ask --engine omp:opencode --slot flash --role security --brief "$BRIEF" --out "${OUT_FLASH}_$i" --repo "$PWD" --deadline 20m
  done
  ```

  Security is a high-stakes role: a capped slot reroutes to `omp:codex` (not to its slot fallback), unless
  `omp:codex` already took part, in which case the run continues with fewer engines and the report says
  so (`degraded=<n>-engines`); `omp:codex` is never counted twice. The flash runs are repeated samples of
  one engine: count them once for agreement. The omp output is untrusted analysis text and Claude verifies
  every candidate against the source before the synthesizer adjudicates; an engine that exits 3, 4 or 5 is
  named in the report as unavailable, never counted.
- **`domain-integrity.md`** — the project's own domain audit agent, **only when it is
  configured.** The shipped file is a template (`templates/security-domain-integrity.md`),
  never an agent. Check before dispatching:

  ```bash
  f=.claude/agents/codebase/security-audit/domain-integrity.md
  if [ -f "$f" ] && ! grep -q 'STUB TEMPLATE' "$f"; then echo configured; else echo unconfigured; fi
  ```

  `configured` → dispatch it with the cartographer's map. Engine choice follows the
  same rule as below: if the invariant is anchored to a deterministic generated + run
  test suite (the gold standard), single-engine suffices; otherwise add the omp security roster
  as above for recall. `unconfigured` → **skip the lens explicitly**: do
  not dispatch a stub, and write "domain-integrity lens: skipped (not configured)" in
  the report so the gap is visible. The template's own file explains how to fill it in.

## Stage 3 — Synthesis (1 agent, strong, single-engine)

```
Agent tool:
  prompt: "Read .claude/agents/codebase/security-audit/audit-synthesizer.md and follow it.
           Adjudicate the union of candidate findings from Stage 2. DEMAND EVIDENCE
           (exploit path / call chain / failing deterministic test) before a finding
           survives; dedupe; rank severity × exploitability; map to ASVS 5.0 L2 IDs;
           attach runtime error-monitoring context where relevant; write confirmed
           systemic patterns to memory (if this project has a memory MCP)."
```

Cross-model agreement is a **priority booster, not a survival gate**. The synthesizer's
job is precision: a candidate without a demonstrable exploit path or failing test does not
ship.

## MCP usage (adapt to what this project actually has configured)

A database/schema-inspection MCP (policy read + running a generated isolation test, if
this project is multi-tenant and has one), a codebase-search MCP (trace auth/domain
flows across files), the LSP (call-graph reachability for IDOR), a secrets MCP (no
service-key leakage), an error-monitoring MCP (runtime context on confirmed findings),
a memory MCP (persist confirmed design-level patterns) — use whichever of these this
project has wired up; skip the ones it doesn't.

## Cut from the old design (do not re-add)

- The 2 checklist-**perturbation** passes — order-bias is already handled by multi-engine
  union-merge.
- The ASVS **input-output** domain agent and anything re-deriving injection / secrets /
  XSS — deterministic-SAST + diff-review territory.
- **Kept:** ASVS Level 2 — but as the synthesizer's *reporting / coverage taxonomy*
  (ASVS 5.0 IDs), not the agent decomposition. Agents are organized by LLM strength;
  findings map back to ASVS at the end.

## Thresholds that change this

- Synthesizer confirmed-finding precision < ~50% → add a mandatory PoC/exploit-repro gate
  (do NOT add passes).
- Claude/omp finding-overlap > 90% over several runs → drop those agents to single-engine.
- If `domain-integrity.md`'s invariant has a deterministic test suite comprehensive
  enough to run per-PR in CI → downgrade that Stage-2 agent to a quarterly pass; rely on
  the deterministic tests as the continuous gate.

## Caveat (keep visible in the report)

An LLM "all clear" is not proof of security — single-pass recall on hard logic bugs can be
< 10%. A deterministic-test-grounded domain-integrity layer (if this project has one) is
the one place you get a real guarantee; everywhere else this audit raises signal, it does
not certify. Treat it as a high-recall hypothesis generator feeding a deterministic
backstop.

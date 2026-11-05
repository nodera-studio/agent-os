# Debug Workflow

Heavy investigation workflow for systematic root cause analysis. Not for everyday debugging -- use when you are stuck and need a methodical, exhaustive investigation.

```mermaid
flowchart TD
    B["/deep-debug &lt;bug description&gt;"] --> T["2-minute triage<br/>(often ends the investigation early)"]
    T -.->|"production issue exists"| SEN["Pull Sentry runtime context<br/>(issue, trace/spans, Seer)"]
    T --> ENGINES
    SEN --> ENGINES

    subgraph ENGINES["Mandatory multi-engine dispatch — parallel, independent"]
        direction LR
        C["Claude subagent<br/>investigator.md<br/>(queue.md from the queue-agents pack)"]
        O["omp investigator (read-only)<br/>omp-engine.sh debug, per row of<br/>routing.sh engines debug"]
    end

    ENGINES --> M["Cross-reference the reports"]
    M --> ADV["Mandatory adversarial verification<br/>(adversary.md, fresh context,<br/>max 3 cycles) — tries to DISPROVE<br/>the leading hypothesis"]
    ADV --> RC["Evidence-verified report<br/>(never fixes the bug — you decide<br/>whether to fix manually or run /implement)"]
```

The adversarial step is the point: a hypothesis that survives someone actively trying to
disprove it (checking it against real code and runtime evidence, not just plausibility)
is worth acting on. One that doesn't survive sends you back to investigate, cheaper than
shipping a wrong fix.

## Specialists

| Agent | File | Focus |
|-------|------|-------|
| `debug-investigator` | `investigator.md` | General application errors -- request flows, stack traces, logs, state |
| `debug-adversary` | `adversary.md` | Mandatory hypothesis-disproving pass before any root cause is reported |

The `queue-agents` pack (`install.sh --pack queue-agents`) adds `debug-queue` (`queue.md`) for background-job and
async-pipeline failures -- stalled jobs, stuck processing, worker issues -- and a queue scanner for `/error-audit`.

## Entry Point

Invoke via `/deep-debug` slash command. Multi-engine dispatch is mandatory — cross-model
consensus is the point of this workflow, not an optional extra. The second engine comes from
`routing.sh engines debug` (by default `omp:opencode/glm`), is read-only, and its report is untrusted
analysis text. The adversary always attacks the leading hypothesis on a different engine than the one that
wrote it. A skipped or capped omp engine is reported as unavailable and the run says it was single-engine.

## When to Use

- A bug persists after initial investigation
- Processing is stuck with no obvious cause
- Error messages are misleading or absent
- Multiple systems interact and the failure point is unclear

## When NOT to Use

- Simple bugs with clear stack traces -- just fix them
- Configuration issues -- check `.env` files and Docker logs directly
- Known issues documented in `docs/` -- read the docs first

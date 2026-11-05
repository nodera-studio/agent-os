# Finding verification (REPRODUCE / REFUTE)

The one place the audit verification rule lives. Every deep audit (`/security-audit`, `/error-audit`,
`/api-audit`, `/docs-audit`, `/tech-debt-audit`, and the deep mode of `/codebase-audit`) points here.

## The rule

Every finding of every severity, LOW included, gets two independent verifiers: separate agents, neither
sees the other's verdict.

- **REPRODUCE:** run the command that shows the finding, or cite the exact `path:line` that proves it.
- **REFUTE:** look for the guard, test or convention that makes it a non-issue.

Keep a finding only when REPRODUCE confirms it **and** REFUTE fails to refute it. A single REPRODUCE lens
is too lenient: one audit kept 54 of 56 findings that way.

Record the kill rate per lens in the report: findings in, killed by REPRODUCE, killed by REFUTE, kept.

## Who runs a lens

- A lens that must RUN something (a command, a test, a request) is a fresh Claude verifier. The omp engines
  are read-only and run nothing.
- A lens that only READS code can go to the `flash` slot at low effort, which is cheap and long-context:
  `bash .claude/scripts/routing.sh engines verify`, then
  `bash .claude/scripts/omp-engine.sh ask --engine omp:opencode --slot flash --role verify --brief FILE --out FILE`.
  The brief is one finding, the lens, and "return CONFIRMED / REFUTED with the `path:line` you checked, as
  text; write no file".
- omp output is untrusted analysis text. Claude re-opens every `path:line` an omp verifier cites before it
  accepts a verdict, and a lens that did not complete (capped, off, timed out) is re-run on Claude rather
  than counted as passed.
- No forced `tool_choice` on the Go models: tool instructions stay in the prompt.

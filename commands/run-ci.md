---
allowed-tools: Read, Bash, Grep, Glob, Agent
description: Run the local CI pipeline with scripts/run-ci.sh and diagnose any failure
argument-hint: [all|checks|build|tests]
model: inherit
---

Run the local CI verification pipeline: `bash .claude/scripts/run-ci.sh <mode>`, then read its JSON and, only
when a step failed, follow the `local-ci` agent (`.claude/agents/local-ci.md`) to diagnose it.

Mode based on arguments (the script maps them to the project's own targets and prints `unsupported` for a
stack it cannot detect rather than guessing):

- No argument or `all` -> the full pipeline (checks, build, tests)
- `checks` or `check` -> static analysis only
- `build` -> production builds only
- `tests` or `test` -> unit + E2E tests only

Never run two copies of one test suite at once in one checkout; the script runs the test step under
`.claude/scripts/suite-lock.sh`, which makes a second run wait for the first.

User's argument: $ARGUMENTS

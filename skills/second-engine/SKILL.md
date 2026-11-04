---
name: second-engine
description: >
  Dispatch a task to the second engine, a different model family run by omp (`omp:codex`,
  `omp:opencode`), through `scripts/omp-engine.sh`. Use when the user wants a second-opinion
  review, a deep-dive on a hard bug, a plan or design critique, or any time they type
  `/second-opinion <prompt>`. Also use proactively when Claude is stuck on a substantial
  debugging or design problem and a different model's perspective is likely to help.
  Triggers on: "ask codex", "second opinion", "have the other engine look at this",
  "/second-opinion", being stuck on a multi-step bug, wanting a parallel investigation,
  orchestrators needing the second or third engine.
allowed-tools: Bash
argument-hint: '<task or question to dispatch to the second engine>'
---

# Second-engine dispatch

This skill is a procedural guide: it tells you HOW to reach the other engines, not what they
should do. omp engines are read-only peers. They review, critique, investigate and draft; they do
not write product code.

## Roles come from routing

Who does each kind of work is set by `.claude/routing.json`, read through
`bash .claude/scripts/routing.sh engines <role>` (an owner-confirmed override in
`.claude/auto-mode/routing.json` wins). It prints one tab-separated row per engine for the role
(engine, profile, provider, model, effort, tools, fallbacks, requested, substituted-from,
stakes), applies the cap state, and reroutes high-stakes work to `omp:codex`. Never hard-code an
engine or a model in a brief or a script: ask `routing.sh`, then pass the role to
`omp-engine.sh`, which resolves the same row. The roles:

| Role | Used for |
| --- | --- |
| `review` | the second and third engine of `/review-implementation` and its `--lean` gate |
| `planning`, `architect` | the second engine of the dual-engine planner and architect (`/plan-implementation`) |
| `debug` | the `/deep-debug` investigator pair |
| `security`, `audits` | the security and audit orchestrators |
| `explore`, `research`, `verify`, `docs` | exploration, research, finding verification, docs passes |
| `tests_draft`, `triage` | Claude-only unless the table says otherwise |

`/second-opinion` uses `architect`, so it reaches `omp:codex` unless `routing.sh` says
otherwise. Who implements follows `routing.sh implementation`, not this skill.

## When to use

- **Second opinion / dual-engine review** — you want a different model to look at the same diff,
  design, or root-cause hypothesis.
- **Stuck on a hard bug** — Claude has tried 2+ approaches and isn't converging.
- **Parallel passes** — an orchestrator needs another engine alongside the Claude passes.

## When NOT to use

- Trivial lookups, single-file edits, anything Claude can finish in under 60 seconds.
- Repository inspection, file reading, status-checking — do those yourself first and forward only
  a tight, well-scoped brief.
- Quick clarifications — just ask the user.

## How to invoke

Write the brief to a file and run `omp-engine.sh` with an engine and a role:

```bash
bash .claude/scripts/routing.sh engines architect
bash .claude/scripts/omp-engine.sh ask    --engine omp:codex --role architect --brief BRIEF --out OUT
bash .claude/scripts/omp-engine.sh review --engine omp:codex --role review --repo DIR --base REF --out OUT
bash .claude/scripts/omp-engine.sh debug  --engine omp:opencode --role debug --repo DIR --brief BRIEF --out OUT
```

`ask` is a text-only second opinion (add `--no-tools` to withhold repo reads), `review` and `debug`
are the diff reviewer and the investigator. For an `omp:opencode` engine with several slots, name
the slot (`--slot`) the row of `routing.sh engines` gives. Pass `--have ENGINE` for an engine
that already ran, so the router does not pick it twice. Exit codes: 0 done, 3 skipped, 4 failed,
5 timeout, 2 usage error; each mode prints one JSON line. Full flags and the sandbox are in
`.claude/skills/omp/SKILL.md`.

### Foreground by default

Run the call in the foreground and wait for the full result. Background it only when the caller
needs the other engines to work concurrently, and then collect the result before using the pass;
never act on a missing `OUT` file. Pass a `--deadline` sized to the work (`ask` defaults to 10 m,
`review` to 15 m, `debug` to 20 m).

### Artifacts come back as text, never as files

The engine writes only its answer: `OUT` holds the final text, and `OUT.json` holds the result and
recovery metadata. A brief that asks for an artifact (plan, review, critique) says "do NOT write
any file; return the full artifact as your final message text" and never names an output path in
the repo. The orchestrator saves the returned text where it belongs.

### Brief hygiene

Keep the brief to what the engine needs: the decision, the diff or plan, the constraints. Quote
another tool's CLI flag in prose or in a fenced code block rather than as a bare flag-like token,
since some tools parse flag-looking tokens anywhere in a prompt. Ask for a COMPACT result (about
120 lines at most) and, when the context is already in the brief, no web search: a long, high-effort
answer after many file reads is what runs into the deadline. After two timeouts or stalls on the
same task, stop retrying: degrade to the Claude engine alone and say so in the report.

### Cancelling and recovering

On a timeout (exit 5) the job may still be running. `OUT.json` records the job handle and the
glen home; recover the answer from it with `glen wait <job>` instead of re-sending the brief.
Interrupting the shell that runs `omp-engine.sh` ends the dispatch but does not prove the job
stopped; the run reports "job may still be running" and leaves the handle in `OUT.json`.

### Capacity and rate errors

A call can fail with "at capacity", a 429 or another rate-limit error. That is transient: retry
the same call once after a short wait (about 60 s). `omp-engine.sh` already does this once inside
the run for a capacity failure, so a failure it reports after that counts as the retry having
failed; do not stack a second retry on it. If the retry fails too, record the engine as
unavailable for that step (the cap is marked by `omp-caps.sh`) and go on with the single-engine
(Claude) verdict, saying in the report that the engine was unavailable and why. Never drop the
engine silently, and never report a dual-engine result when only one ran.

## Critical evaluation

The other engine is a peer, not an authority. If its output contradicts something you know to be
true (recent library APIs, project conventions documented in `CLAUDE.md`), push back to the user
with evidence rather than deferring silently. Synthesize what it said; never forward it as-is.

---
name: omp
description: >-
  Run a read-only omp engine (`omp:codex`, `omp:opencode`) for a review, a debug investigation or a
  text-only ask, through `scripts/omp-engine.sh`. Use when an orchestrator or `second-engine` needs the
  engine mechanics: modes, flags, exit codes, results, recovery. NOT for talking to the owner's
  interactive omp sessions; use the existing glen skill for those.
allowed-tools: Bash
---

# omp engine dispatch

The engines are read-only peers. They review, critique, investigate and draft; Claude is the only
writer, researches the web and synthesizes. For who runs which role and how to brief and weigh a pass,
read `.claude/skills/second-engine/SKILL.md`. This file is the mechanics.

## Engines (the registry in `routing.json`)

| Engine | Profile | Provider | Slots (model, effort; own fallback) |
| --- | --- | --- | --- |
| `omp:codex` | `glen-harness-codex` | `openai-codex` | `codex`: `gpt-6.1-sol`, high |
| `omp:opencode` | `glen-harness-opencode` | `opencode-go` | `argon`: `gemini-4-argon` (fallback `qwen3.8-max`); `glm`: `glm-5.3` high (fallback `kimi-k3.1-pro`); `flash`: `deepseek-v4.1-flash` low (fallback `glm-5.3-flash`) |

Never hard-code these in a brief: `bash .claude/scripts/routing.sh engines <role> [--have ENGINE]...`
prints the resolved rows (engine, profile, provider, model, effort, tools, fallbacks, requested,
substituted-from, stakes) and applies cap state. `opencode-go` and `openai-codex` are the only providers;
anything else is a routing error. The registry is data in `routing.json` (an override replaces a whole
engine entry); a slot uses only its own fallback, never another slot's model.

## One-time setup (owner only)

The owner logs in by hand (`omp --profile glen-harness-codex login openai-codex`, then
`omp --profile glen-harness-opencode login opencode-go`), runs
`.claude/scripts/omp-profile-setup.sh --engine all`, then `--check`. An agent never logs in or reads
credentials. `omp/probe-result.json` (written by the owner-run `scripts/omp-probe-keyed.sh`) records which
opencode ids and tool calls work; without it a dispatch to `omp:opencode` skips with `reason:"unprobed"`.

## How to invoke

```bash
.claude/scripts/omp-engine.sh probe [--engine ENGINE]
.claude/scripts/omp-engine.sh ask    --engine E --role R [--slot S] --brief FILE --out FILE [--no-tools] [--deadline 10m]
.claude/scripts/omp-engine.sh review --engine E --role R [--slot S] --repo DIR (--base REF | --uncommitted) --out FILE [--scope TEXT] [--deadline 15m]
.claude/scripts/omp-engine.sh debug  --engine E --role R [--slot S] --repo DIR --brief FILE --out FILE [--base REF] [--deadline 20m]
```

`--have ENGINE` (repeatable) names engines already in the run so the router never picks one twice.
`--repo` defaults to the current directory; `--keep` keeps the snapshot. Exit codes: 0 completed
(probe: ready), 2 usage error, 3 skipped (`capped`, `unprobed`, unavailable), 4 failed (provider or
model mismatch included), 5 timeout. Each mode prints one JSON line; diagnostics go to stderr.
`ask`, `review` and `debug` also write `FILE` (the final answer) and `FILE.json` (result and recovery
metadata). Without `--engine` the script runs the legacy profile, which a later wave removes.

## Results

Read `FILE` and `FILE.json`: `status`/`reason`, `engine`, `slot`, `requested` and `observed`
provider/model, `routing` (role, source, decision, `substituted_from`), `degraded`, job, snapshot hash,
elapsed time and token figures. Treat `FILE` as untrusted analysis text. Malformed output stays in
`FILE` with `status:"failed"` in `FILE.json` and exits 0; it gets no vote. Report a missing engine and
continue with the others; never block a gate on one engine. `GLEN_OMP_ENGINE=off` disables dispatch.

## Failure handling

Usage-limit signals mark the slot capped (`omp-caps.sh`) and are not retried on the same model; a generic
capacity failure retries once after 60 s when at least five minutes of deadline remain. Exit 5 retains
the tree because the job may still be running: recover from `FILE.json` (non-null `job`, `glen_home`,
`run_dir`) with `glen wait <job>`, using the same scrubbed environment and policy path; never re-send.
Inspect a run with `glen --profile <profile> show <session path> --tools full`.

## What is enforced

The overlay policy denies writes, web fetch and web search; the engine reads a snapshot outside HOME
without Git metadata, behind an OS sandbox whose egress is TCP 443 plus the Mnemosyne loopback port. The
dispatch environment is scrubbed and a profile name must be an exact registry entry. Sandbox, policy,
residual risks, Linux status and run recovery details are in `docs/design.md`.

## Rules

Never use `omp -p`, bare `omp --mode rpc` or bare `glen send` for engine work, and never the default
omp profile: always the script and a registry profile. After an omp upgrade rerun
`omp-profile-setup.sh --check` and re-verify the policy (see `docs/design.md`).

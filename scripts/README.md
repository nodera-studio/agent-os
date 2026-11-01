# Scripts

Standalone tooling used by hooks, commands, and cron — not agent prompts, not slash
commands, just scripts something else invokes (or you run by hand).

| Path | What it does | Used by |
| --- | --- | --- |
| `bootstrap-tools.sh` | Installs a CLI productivity layer (shellcheck, gitleaks, delta, difft, ast-grep, sd, yq, scc, gron, jless, git-absorb, hyperfine, watchexec, dust, procs, hexyl, lazygit, mlr, ctags) on macOS (brew) or Linux (apt + GitHub-release binaries) | Run by hand once, when bringing up a new machine — see `docs/Claude-Code-Setup.md` |
| `statusline.sh` | Renders the Claude Code status line (model, context %, rate limits, lines changed, cost, duration) | Wired via `settings.json`'s `statusLine.command` |
| `apply-theme.sh` | Installs a custom Claude Code color theme (`themes/linear-dark.json` by default) into `~/.claude/themes/` and points `~/.claude/settings.json`'s `theme` key at it | Run by hand once per machine — see `docs/customizations/theme-setup.md` |
| `orchestrator/record-gap.mjs` | Appends a gap record to `.claude/orchestrator/gaps.jsonl` + `GapLog.md` when `/orchestrate` mode spawns a one-off subagent with no matching harness agent | Called from `agents/orchestrator/orchestrator-mode.md`, read back by `/audit-agent-gaps` |
| `brainstorm/` | A tiny local Node server (`server.cjs` + `helper.js` + `frame-template.html`) that renders browser-based mockups for the `/brainstorm` skill's optional visual-exploration mode | Started/stopped by `start-server.sh`/`stop-server.sh`, invoked from `agents/brainstorm.md` |
| `mnemosyne/` | The learned-rules-loop scripts (`record-finding.mjs`, `distill.sh`, `weekly-digest.sh`, `promote.mjs`, `retire.mjs`) — read/write your project's OWN Postgres (`DATABASE_URL`), not any Mnemosyne server's database | The `mnemosyne-capture.sh` hook (recording) + your own cron (distilling/promoting) — see `docs/LearnedRulesLoop.md` for the schema and workflow |
| `cron/` | Reference cron wiring for the Mnemosyne codebase-MCP reindex job | Nothing auto-installs this — see `cron/README.md` for the manual install steps |
| `routing.sh` | `routing.sh <key>`: prints who does a kind of work (`implementation`, `ui`, `review`, `planning`, `debug`, `audits`, `integration`) or a fan-out cap (`heavy_concurrency`) from `routing.json`; an owner-confirmed `.claude/auto-mode/routing.json` overrides per key; exit 2 on an unknown key or broken JSON | Every prompt that picks an engine (`/implement`, `/plan-implementation`, `/auto-mode`, the coders) |
| `remove-worktree.sh` | `remove-worktree.sh [--dry-run] [--force-no-state] <worktree> [<branch>]`: removes a `.claude/worktrees/` worktree after stopping its Codex brokers; preserves evidence/plans/reviews into the main checkout; deletes the branch only when its tip is on its upstream or in a base branch on origin (`HARNESS_BASE_BRANCHES`) | `/implement` and `/auto-mode` worktree cleanup |
| `sweep-codex-orphans.sh` | Stops this repo's orphaned codex-companion brokers (worktree gone, no live job); reports suspected orphan tasks without signalling them; `--dry-run` | Wave end and worktree removal |
| `codex-procs.sh` | Shared helpers sourced by the two scripts above: one process snapshot, both companion state stores, PID re-validation, TERM/KILL | Sourced, never run directly |
| `suite-lock.sh` | `suite-lock.sh <command> [args…]`: runs the command while holding a per-checkout lock so two test suites never run at once against one build dir; stale-lock takeover; exit 75 on wait timeout | Wrapping the project's test command in parallel runs |
| `checkpoint-due.sh` | `checkpoint-due.sh [<state-file>]`: reads the `## Checkpoints` section of the auto-mode state file; exit 0 = due, 1 = not due, 3 = no cadence | Every `/auto-mode` wake |
| `clean-scratch.sh` | `clean-scratch.sh [--dry-run] [--min-age <minutes>] <pattern>…`: the sanctioned way for an agent to delete its `$TMPDIR` scratch (`HARNESS_SCRATCH_PREFIX` + glob); refuses symlinks and anything a process or worktree still uses | `steer-bash.sh` redirects `rm -rf` of scratch here |
| `omp-profile-setup.sh` | Idempotently configures the isolated `glen-harness` omp profile, policy, MCP, skill and extension; supports `--model`, `--check`, `--dry-run` and checks the default-profile fingerprint | Run by the owner per machine — see `docs/Claude-Code-Setup.md` |
| `omp-engine.sh` | Optional read-only third review/debug engine run through the `glen` CLI: readiness probe (exit 3 = skip), isolated snapshot/policy/environment, bounded send/wait and one capacity retry; writes final text and result JSON | The review gates and optional `/deep-debug` investigator via `skills/omp/SKILL.md` |
| `../omp/` | The omp engine's assets: `glen-harness.yml` (approval policy + read containment), `mcp.json`, `model-ladder.sh`, `omp-sandboxed.sh` / `omp-sandboxed-linux.sh`, and the `skills/` the isolated profile loads | Read by `omp-profile-setup.sh` and `omp-engine.sh`; never edited at run time |
| `tests/omp-engine-smoke.sh` | Offline probe, snapshot, capture-race, policy-source, dispatch-environment and profile-guard smoke tests, compatible with Bash 3.2 | Run with `/bin/bash .claude/scripts/tests/omp-engine-smoke.sh`; no live omp login needed |
| `tests/omp-profile-setup-smoke.sh` | `omp-profile-setup.sh` against stub `omp`/`glen` binaries in a throwaway HOME (setup, `--check`, `--dry-run`) | Run with `/bin/bash .claude/scripts/tests/omp-profile-setup-smoke.sh` |
| `tests/steer-omp-profile-smoke.sh` | Checks that `hooks/steer-bash.sh` denies omp with a profile other than `glen-harness` and writes into another `~/.omp/profiles/<name>`, and allows the throwaway-HOME form | Run with `/bin/bash .claude/scripts/tests/steer-omp-profile-smoke.sh`; needs jq |
| `tests/support/` | Stub `glen` and `omp` executables the omp smoke tests put on `PATH` | Used only by the omp smoke tests |
| `tests/*-smoke.sh` | Offline smoke tests for the scripts and hooks above (routing, suite-lock, checkpoint-due, clean-scratch, remove-worktree, codex job listing, secret-paste, capture-before-merge waiver, squash-merge recipe) | Run each with `/bin/bash .claude/scripts/tests/<name>.sh`; exit 1 on any FAIL |

## Two different "Mnemosyne" things, easy to conflate

- **`scripts/mnemosyne/`** — the learned-rules distillation loop. Reads/writes tables
  (`rule_findings`, `rule_candidates`) in **your own project's Postgres**. This is a
  harness feature: it captures episodic fixes during sessions and periodically distills
  them into promotable `CLAUDE.md` conventions. Fully optional; needs no external server.
- **`scripts/cron/mnemo-reindex.sh`** — talks to the separate **Mnemosyne MCP server**
  (the memory/codebase/secrets stack — see `skills/mnemosyne/SKILL.md`), which is its
  own project you run yourself, not something this repo ships. This script just
  triggers that server's codebase reindex on a schedule.

Neither requires the other. You can run the learned-rules loop with zero Mnemosyne MCP
server, and you can run the Mnemosyne MCP server without ever touching the learned-rules
loop.

The `omp-*` smoke tests resolve the harness through a git checkout that has it installed as `.claude/` (what `install.sh` produces), so run them from an installed project, not from this template repo.

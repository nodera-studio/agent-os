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

# Changelog — omp engines replace Codex

What moved where, so a project that installed an earlier agent-os can migrate. Nothing is deleted from a target by
`install.sh`: files the harness no longer ships stay where they are until you remove them, and an unmodified
leftover is safe to delete.

## Behaviour changes

| Area | Before | Now |
| --- | --- | --- |
| Who writes code | Claude or native Codex | Claude only (`routing.json` → `implementation`). No omp mode writes files. |
| Review, planning, debug, audits | `["claude","codex"]` (native Codex, write-capable CLI) | The read-only omp engines: `review` and `planning` = `claude`, `omp:codex`, `omp:opencode/argon`; `debug` and `audits` = `claude`, `omp:opencode/glm`. Ask `bash .claude/scripts/routing.sh engines <role>` for the live, cap-aware roster. |
| Native Codex | Core | Opt-in `codex` pack. `omp_fallback` is empty by default, so a capped engine is skipped, never swapped for native Codex. |
| omp profiles | One legacy `glen-harness` (Cursor) profile plus a model ladder | Exactly `glen-harness-codex` and `glen-harness-opencode` (`omp/profiles.sh`). `omp/model-ladder.sh` and `omp-profile-setup.sh --model` are gone; `omp-profile-setup.sh` and `omp-engine.sh` require `--engine`. |
| Quick lanes | `/implement-quick`, a `minimal` planning depth, a single-planner gate | Removed. Planning always runs the explorer, the researcher and the dual-engine architect and planner. |
| Budgets | none | `omp_engines.<engine>.slots[].budget` (`window_hours`, `max_calls`, `max_usd`), all `null` until the owner sets them. |

### Adopting the new routing defaults in an existing project

`routing.json` is seeded once and never overwritten, so a project installed earlier keeps `["claude","codex"]`
until you change it, and `install.sh` prints a note when its file differs from the release default. A pack's
`routing` fragment only fills keys that are unset, so it cannot do this either. To adopt the defaults, copy these
keys from the release `routing.json` into the project's: `review`, `planning`, `debug`, `audits`, `omp_engines`,
`omp_roles`, `omp_fallback`. Keep your own `implementation`, `ui`, `integration` and `heavy_concurrency`. Then run the
owner setup in `docs/Claude-Code-Setup.md` (`omp-profile-setup.sh --engine all`). To keep native Codex, install the
`codex` pack and set the keys yourself. An override in `.claude/auto-mode/routing.json` still wins per key.

## Agents

| Old | New |
| --- | --- |
| `implementation/coder-claude.md` | `implementation/implementer.md` (`impl-implementer`) |
| `implementation/coder-codex.md` | cut (no Codex writer) |
| `implementation/orchestrator-quick.md` | cut |
| `implementation/planner.md` | `plan/planner.md` |
| `implementation/code-review.md`, `review-implementation/comprehensive-review.md` | `review/claude-reviewer.md` (`depth: lean` or `full`) |
| `plan/researcher.md` | `research/agent.md` (`mode: plan`) |
| `codebase/error-audit/backend.md`, `frontend.md` | `codebase/error-audit/scanner.md` (with a scope) |
| `codebase/docs-expert.md` | cut (the codebase MCP answers it) |
| `codebase/security-audit/domain-integrity.md` | `templates/security-domain-integrity.md` (copy it to opt in) |
| `copywrite/*` (`line-editor`, `microcopy-patterns` merged into `voice-editor` and `microcopy-specialist`) | `copywrite` pack |
| `orchestrator/*` | `orchestrator` pack |
| `codebase/error-audit/queue.md`, `debug/queue.md` | `queue-agents` pack |
| (new) | `codebase/verification.md` |

## Commands

| Old | New |
| --- | --- |
| `/goal` | `/auto-mode` |
| `/codex`, `/codex-advisor` | `/second-opinion [--advisor]` (omp `ask`); the native Codex flows are in the `codex` pack's skill |
| `/code-review` | `/review-implementation --lean` |
| `/implement-quick` | cut |
| `/copywrite` | `copywrite` pack |
| `/orchestrate`, `/audit-agent-gaps` | `orchestrator` pack |
| `/security-scan` | `security-scan` pack |

## Skills

| Old | New |
| --- | --- |
| `codex` | `codex` pack |
| `branching-model`, `promote-to-prod` | `release-flow` (`references/promote-runbook.md`) |
| `mnemosyne` | cut; the `mnemosyne` plugin skill and your global CLAUDE.md replace it (`rules/mnemosyne-notes.md` keeps the one extra fact) |
| `wrangler` | cut; use the `wrangler` and `cf-cli` plugin skills |
| `playwright-cli`, `linear`, `sentry-cli` | `playwright`, `linear`, `sentry-cli` packs |
| (new) | `second-engine` (engine dispatch and the role table), `omp` (the engines' operating guide) |

## Hooks and scripts

| Old | New |
| --- | --- |
| `block-old-codex.sh` | `codex` pack; core wires `block-legacy-engines.sh` (denies `codex exec` and a bare `omp` by command word) |
| `prettier-on-edit.sh`, `shellcheck-on-edit.sh` | `post-edit-lint.sh` |
| `session-start.sh` | folded into `reinject-invariants.sh`; the orchestrator notice moved to the `orchestrator` pack |
| `mnemosyne-capture.sh`, `scripts/mnemosyne/{distill,digest,promote,retire,record-*,query-findings}` | `learned-rules` pack |
| `scripts/codex-procs.sh`, `scripts/sweep-codex-orphans.sh` | `codex` pack |
| `scripts/orchestrator/record-gap.mjs` | `orchestrator` pack |
| `hooks/README-optional-hooks.md` | merged into `hooks/README.md` |
| (new) | `run-ci.sh`, `dep-audit.sh`, `merge-trunk.sh`, `poll-pr.sh`, `close-run.sh`, `promote-preflight.sh`, `seam-overlap.sh`, `stale-reference-scan.sh`, `tech-debt-scan.sh`, `endpoint-inventory.sh`, `copywrite-checks.sh`, `blind-candidates.sh`, `check-refs.sh`, `omp-caps.sh`, `omp-probe-keyed.sh`, `routing.sh engines` |

## Packs

`install.sh <target> --pack NAME` installs an optional pack, `--remove-pack NAME` removes only what is unchanged
since install, and `install.sh --list-packs [<target>]` lists them. Packs: `auto-mode-extras`, `codex`, `copywrite`,
`learned-rules`, `linear`, `orchestrator`, `playwright`, `queue-agents`, `security-scan`, `sentry-cli`. See
`packs/README.md` for the ownership manifest and conflict rules.

## Upgrading an installed project

Re-run `./install.sh <target>`. It overwrites the core files the harness ships with the new versions (keep
project-specific changes in files the harness does not ship), never overwrites your `settings.json`, `CLAUDE.md`
or `routing.json`, and deletes nothing, so files from the old layout stay where they are. Install a pack
(`--pack NAME`) for the features that moved there: a leftover file identical to a known earlier pack version is
adopted or replaced, and one you edited is kept and reported as a `CONFLICT` (exit 3) for you to merge by hand.
Then adopt the routing defaults above, delete the old-layout files you did not edit (the tables name them), and
run the owner setup for the engines you want.

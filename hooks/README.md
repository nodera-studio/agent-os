# Hooks

Enforcement scripts wired into `settings.json` against Claude Code's lifecycle events
(`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `PreCompact`). Two postures, used
deliberately per hook:

- **Warn-don't-block** — prints guidance, exits 0. Used where a wrong call is annoying,
  not dangerous (formatting, shellcheck nits, a reminder).
- **Hard block** — exits 2 with a message explaining what to do instead. Used only where
  the thing being blocked is a real, specific footgun (a dropped legacy code path, a
  merge with no captured decision) — never as a blanket "be careful" gate.

## What ships, wired in `settings.json`

| Hook | Event | Posture | What it does |
| --- | --- | --- | --- |
| `reinject-invariants.sh` | `SessionStart` (every start), `PreCompact` | info | Re-injects a short, project-defined invariants list (`rules/invariants.md`, frontmatter stripped) so it survives context compaction: it reads the SessionStart `source` from the payload and skips the list on `startup` and `clear`, prints it on `resume`, `compact` and `PreCompact`. It prints no list while the payload still holds the template's `[Add your project's` placeholder text, or when the file is missing. Smoke test: `scripts/tests/hooks-smoke.sh` |
| `block-legacy-engines.sh` | `PreToolUse` (`Bash`, `Skill`) | hard block | Denies `codex exec` and a bare `omp` by COMMAND WORD: quotes, comments and heredoc bodies are removed, the line is split at command separators, `env`/`timeout`/`nice`/`sudo` prefixes and `$( )`, backtick, `sh -c` and `eval` payloads are looked through, so the same words in a commit message, `echo` or heredoc are allowed. `omp --version`/`--help` alone and anything run through `scripts/omp-engine.sh` are allowed. The codex pack adds its own plugin-transport guard (Bash only); core does not wire it. Smoke test: `scripts/tests/hooks-smoke.sh` |
| `steer-bash.sh` | `PreToolUse` (`Bash`) | warn (steers) | Redirects risky/inefficient bash patterns (`sed -i` → Edit tool, raw `cat`/`head` of code files (ts/js/css/sql; docs and config such as `.md`/`.json`/`.yaml`/`.toml` stay allowed) → Read tool, `.env` reads → secrets MCP, external `curl` → an allowlisted host check over every URL in the command, recursive `rm` of the project's temp-dir scratch → `scripts/clean-scratch.sh`) toward better tools. Smoke test for the `rm` rule: `scripts/tests/clean-scratch-smoke.sh`. The advice names `HARNESS_CLEAN_SCRATCH` (default `.claude/scripts/clean-scratch.sh`). Also denies an `omp` probe with a profile not in `omp/profiles.sh` (exact names, with a hardcoded fallback list if that file is missing; `--profile`, `OMP_PROFILE`, `PI_PROFILE`) and creating another `~/.omp/profiles/<name>`, pointing to `HOME="$(mktemp -d)"`. Smoke test for the omp rule: `scripts/tests/steer-omp-profile-smoke.sh` |
| `capture-before-merge.sh` | `PreToolUse` (`Bash`, on `gh pr merge`) | hard block | Blocks a PR merge until a durable-memory entry referencing the PR/branch exists in-session (only meaningful if you run a memory MCP). Owner waiver: a main-session owner message such as "no memory for PR #42" (naming the PR) lifts the memory requirement, and the hook then asks the owner to confirm the merge. Smoke test: `scripts/tests/capture-waiver-smoke.sh` |
| `guard-claude-md-name.sh` | `PreToolUse` (`Write`) | hard block | Write tool only (shell redirects and `mv` are covered by the prompts, not this hook). Refuses a new file whose basename is `claude.md` in any case, except `<repo>/CLAUDE.md`, `<repo>/.claude/CLAUDE.md` (per checkout or worktree), `~/.claude/CLAUDE.md` and any `CLAUDE.md` that already exists on disk: Claude Code loads any such file as a nested `CLAUDE.md` on macOS's case-insensitive filesystem. Name per-engine output `<engine>-review.md` / `<engine>-plan.md` |
| `post-edit-lint.sh` | `PostToolUse` (`Edit\|Write`) | warn-don't-block | One jq parse of the edited path, then a dispatch on the extension. `ts`/`tsx`/`js`/`jsx`/`json`/`css`/`scss`: runs the project's local `node_modules/.bin/prettier` only when the nearest `package.json` project configures prettier and has it installed, otherwise silent. `sh`/`bash`: `shellcheck -S warning -f gcc` when shellcheck is installed. Findings and failures reach Claude through `additionalContext`; the hook never exits non-zero and does nothing without jq. Smoke test: `scripts/tests/hooks-smoke.sh` |
| `secret-paste-warn.sh` | `UserPromptSubmit` | hard block (warns by blocking) | Stops a prompt that looks like it carries a credential (GitHub, Anthropic, OpenAI, AWS, Slack, Google, Stripe live key, PEM private key, JWT) before it reaches the model, with `suppressOriginalPrompt` so the text stays out of the block message. The reason names the label and length, never the value. Bypass: start the message with `[allow-secret]`. Fails open without jq. Smoke test: `scripts/tests/secret-paste-smoke.sh` |
| `mnemosyne-capture.sh` | `Stop` | opt-in (`MNEMOSYNE_CAPTURE=1`) | Captures an episodic fix summary into a memory MCP's findings table, if you run one |

## Fill in before this does anything project-specific

Two hooks ship as **mechanism-only placeholders** — they need your project's actual
content before they're meaningful:

- **`reinject-invariants.sh`** — the re-injected payload is `rules/invariants.md`, which ships as a
  bracketed placeholder list ("[Add your project's non-negotiable invariants here]"); the hook
  prints nothing until those placeholders are gone. Replace them with the handful
  of rules your project genuinely cannot afford an agent to forget after a compaction —
  a data-access pattern that must never be bypassed, a testing policy, a git-hygiene
  rule. Keep it short (a few hundred tokens); this re-injects on every compaction, so
  bloat here is a recurring tax.
- **`steer-bash.sh`**'s `ALLOW_HOSTS` allowlist ships with just loopback addresses.
  Add your own trusted remote hosts (an internal API, a deploy target) if your project's
  agents legitimately need to `curl` them. This hook is the enforcement half of a
  larger set of CLI-tool replacements (`rg` over `grep`, `sd`/the Edit tool over
  `sed -i`, `ast-grep`, `difft`, `yq`, `gron`, `scc`, and more) — see
  `docs/Claude-Code-Setup.md`'s "Why these tools" table for the full routing rationale
  and `scripts/bootstrap-tools.sh` for the installer.

## Custom hooks for your project

The source project this harness was extracted from had several more hooks that hardcoded its own
dev-tool, container and monorepo specifics. They were dropped rather than shipped as dead weight, but
the pattern each demonstrated is worth knowing when you `/bootstrap-project` a new repo and decide
which project-specific hooks to author for YOUR stack. None of these is wired into `settings.json`.

| Hook name idea | Event | What it'd enforce |
| --- | --- | --- |
| `enforce-<your-dev-tool>.sh` | `PreToolUse` on `Bash` | Blocks raw dev-server commands (e.g. bare `npm run dev`), steers to your project's canonical dev-start command (e.g. `make dev`). |
| `protect-<generated-artifact>.sh` | `PreToolUse` on `Edit\|Write` | Blocks hand-edits to auto-generated files (migration snapshots, codegen output, lockfiles) that must only be produced by their generator. |
| `protect-<template-dir>.sh` | `PreToolUse` on `Edit\|Write` | Blocks edits to scaffold/template source files from an unrelated task context (guards against accidental cross-contamination of generator templates). |
| `rebuild-<shared-package>.sh` | `PostToolUse` on `Edit\|Write` | Rebuilds a shared internal package after an edit so dependent apps in a monorepo pick up the change immediately. |
| `stop-test-gate.sh` | `Stop` | Blocks session end if typecheck/tests are failing when app code changed this session, forcing a green state before the agent stops. |
| `worktree-<pkg-manager>-install.sh` | `PostToolUse` on `EnterWorktree` (and/or `SessionStart`) | Installs dependencies in a freshly created git worktree so it's immediately runnable. |

Copy the fail-open, non-blocking-unless-warranted style of the hooks that did ship: `post-edit-lint.sh`
for warn-don't-block, `capture-before-merge.sh` for a hard block.

## Writing your own

A hook is a script that reads a JSON payload from stdin (`tool_name`, `tool_input`,
etc. — see any shipped hook for the exact shape), and communicates back via exit code
(0 = allow/continue, 2 = block with the stderr message shown to the agent) or, for
`PreCompact`/`SessionStart`, by printing context to stdout. Wire it into `settings.json`
under the matching event array; use a `matcher` to scope it to specific tools
(`"matcher": "Bash"`, `"matcher": "Edit|Write"`) when it shouldn't fire on everything.

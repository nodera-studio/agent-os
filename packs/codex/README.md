# Pack: codex (native Codex, opt-in)

The native Codex integration that the core harness no longer carries. Core reaches Codex through the
read-only `omp:codex` engine (`scripts/omp-engine.sh`, `skills/second-engine`); this pack keeps the older
route through the openai-codex plugin for projects that still want it.

```bash
./install.sh <target> --pack codex
./install.sh <target> --remove-pack codex
```

## What it ships

| File | Role |
| --- | --- |
| `skills/codex/SKILL.md` | How to dispatch `codex:codex-rescue` / `codex review`, the foreground and artifacts-as-text rules, and the cancel recipe for a Codex job (companion `cancel`, then the worktree's broker tree) |
| `hooks/block-old-codex.sh` | `PreToolUse` on `Bash`: blocks a raw `codex exec`, allows anything through `codex-companion.mjs`. Core's `block-legacy-engines.sh` already denies `codex exec` and the dropped `skill-codex:codex` wrapper, so this is the plugin-transport guard only |
| `scripts/codex-procs.sh` | Companion job and broker listing. `remove-worktree.sh` sources it when present and refuses to remove a worktree that a live Codex job still references |
| `scripts/sweep-codex-orphans.sh` | Stops orphaned companion brokers and reports suspected orphan tasks. `close-run.sh` runs it when present |
| `scripts/tests/codex-jobs-smoke.sh` | Offline test for the job and broker listing |

`pack.json` wires the hook and registers `codex` (disabled) and `omp_fallback` (`[]`) in `routing.json`, only
when those keys are unset.

## Native Codex is not a fallback

- Capacity or rate errors on an omp engine never activate native Codex. The engine script exits 3 with
  `reason:"capped"`, the role degrades and says so, and nothing else runs.
- `omp_fallback` is `[]` by default and stays that way until you set it. The adapter that would honor it does
  not ship.
- **Before you activate it, the fallback adapter needs enforced read-only confinement.** `codex:codex-rescue`
  runs in a `workspace-write` sandbox, so Codex can edit its working directory whatever the brief says. Add
  and test a confinement (a read-only checkout, a sandbox without write, or a diff guard that fails the run)
  before pointing `omp_fallback` at `codex`.
- Claude stays the only writer. Nothing in this pack writes product code.

## Tests

The pack test is not part of the default `harness-smoke.sh` run. Include it with:

```bash
HARNESS_SMOKE_PACKS=codex bash scripts/tests/harness-smoke.sh codex-jobs
HARNESS_SMOKE_PACKS=all bash scripts/tests/harness-smoke.sh        # core suites plus every pack's tests
```

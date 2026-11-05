# Pack: learned-rules (the learned-rules loop)

An optional feedback loop that turns review and fix evidence into promotable `CLAUDE.md` conventions. Everything
here reads and writes **your own project's Postgres** (`DATABASE_URL`: `rule_findings` and `rule_candidates`
tables). It does not talk to the owner's Mnemosyne memory or to any server, which is why the hook is no longer called
`mnemosyne-capture.sh`.

```bash
./install.sh <target> --pack learned-rules
./install.sh <target> --remove-pack learned-rules
```

## What it ships

| File | Role |
| --- | --- |
| `hooks/learned-rules-capture.sh` | `Stop` hook, opt-in (`LEARNED_RULES_CAPTURE=1`; the old `MNEMOSYNE_CAPTURE=1` still works). Records one `episodic_fix` finding per changed source file |
| `scripts/mnemosyne/record-finding.mjs`, `record-candidate.mjs`, `query-findings.mjs` | Write and read the two tables |
| `scripts/mnemosyne/distill.sh`, `distill-prompt.md`, `weekly-digest.sh`, `digest-prompt.md` | The nightly distiller and the weekly digest (cron-invoked) |
| `scripts/mnemosyne/promote.mjs`, `retire.mjs` | Human-gated promotion into `CLAUDE.md`, and retirement of decayed rules |
| `docs/LearnedRulesLoop.md` | Schema and workflow |
| `scripts/tests/learned-rules-smoke.sh` | Offline test for the capture hook against a stub recorder |

`scripts/mnemosyne/capture-findings.sh` (the review gates' structured-capture step) stays in core: without this
pack it reports `skipped` and the gate carries on.

## Configuring the capture hook

The old hook hard-coded `apps/**` and `packages/**` and a list of illustrative categories. Now:

- `LEARNED_RULES_PATHS` (default: the whole repository) and `LEARNED_RULES_EXT` (default `ts|tsx|js|jsx`) say
  what to watch.
- `.claude/learned-rules-categories.txt` maps paths to categories, one `<shell-glob> <category>` per line, first
  match wins. Without it a path is `uncategorized`; the distiller refines categories later.

## Upgrading from the old hook

Older installs wired `hooks/mnemosyne-capture.sh` in `settings.json`. `install.sh` never deletes a file or edits an
existing `settings.json` entry, so after `--pack learned-rules` remove that old entry and delete the old file by hand;
otherwise both hooks record every changed file when the opt-in variable is set.

## Requirements

`node`, `jq` and a Postgres reachable through `DATABASE_URL`. The hook exits 0 whatever happens, so a missing
dependency only means nothing is recorded.

Pack tests: `HARNESS_SMOKE_PACKS=learned-rules bash scripts/tests/harness-smoke.sh learned-rules`.

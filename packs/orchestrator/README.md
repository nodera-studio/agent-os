# Pack: orchestrator (dispatch-only mode and the agent-gap loop)

An optional meta-loop around `gaps.jsonl`. `/orchestrate` turns the main session into a pure dispatcher: match an
existing agent, command or skill first, spawn a scoped one-off only when nothing fits, and log that gap.
`/audit-agent-gaps` clusters the log and proposes promoting a recurring shape into a permanent agent, reporting
first and writing only on explicit approval. It is niche and prompt-only (no hook enforces "never edit directly"),
so core does not carry it.

```bash
./install.sh <target> --pack orchestrator
./install.sh <target> --remove-pack orchestrator
```

## What it ships

| File | Role |
| --- | --- |
| `commands/orchestrate.md` | Toggles the mode; writes or removes the `.claude/.orchestrator-mode` marker |
| `commands/audit-agent-gaps.md` | Dispatches the gap auditor |
| `agents/orchestrator/orchestrator-mode.md` | Governing prompt: match first, one-off and log, never edit directly |
| `agents/orchestrator/gap-auditor.md` | Clusters open gaps, proposes promotions, writes only after approval |
| `agents/orchestrator/README.md` | Dispatch-loop and promotion diagrams |
| `scripts/orchestrator/record-gap.mjs` | Appends a gap to `.claude/orchestrator/gaps.jsonl` and `GapLog.md` (plain node) |
| `hooks/orchestrator-mode-notice.sh` | `SessionStart`: prints a one-line notice while the marker exists |
| `scripts/tests/orchestrator-smoke.sh` | Offline test for `record-gap.mjs` and the notice hook |

## Ownership of the gap log

The installer seeds nothing. `record-gap.mjs` creates `.claude/orchestrator/GapLog.md` from its built-in scaffold on
the first gap, so the project owns the log from then on: a pack upgrade or removal never touches `gaps.jsonl` or
`GapLog.md`. A project that installed the old core harness already has a seeded `GapLog.md`; it keeps working.

## Requirements

`node` on `PATH`. The notice hook used to live in core's `reinject-invariants.sh`; core no longer prints anything for
the marker, so a stale marker without this pack is harmless.

Pack tests: `HARNESS_SMOKE_PACKS=orchestrator bash scripts/tests/harness-smoke.sh orchestrator`.

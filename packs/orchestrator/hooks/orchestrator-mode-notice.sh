#!/usr/bin/env bash
# SessionStart. When /orchestrate has left its marker (.claude/.orchestrator-mode) in the project root, say so on
# every session start (startup, resume, compact, clear). Prints nothing without the marker. Ships with the
# orchestrator pack; core's reinject-invariants.sh no longer knows about orchestrator mode.
set -uo pipefail

if [ -f .claude/.orchestrator-mode ]; then
  echo "Orchestrator mode is ON (dispatch-only — see .claude/agents/orchestrator/orchestrator-mode.md). Run /orchestrate off to disable."
fi
exit 0

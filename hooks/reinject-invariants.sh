#!/usr/bin/env bash
# SessionStart (every start) + PreCompact. Two jobs:
#   1. the orchestrator-mode notice: when .claude/.orchestrator-mode exists, say so on any session start.
#   2. re-inject the project's non-negotiable invariants so long autonomous/agentic runs survive
#      compaction. The payload is rules/invariants.md (frontmatter stripped); keep it < ~500 tokens.
#      A fresh start or /clear (SessionStart source startup|clear) skips it; resume, compact and
#      PreCompact print it. While the file still holds the template's placeholder text the hook prints
#      no payload: a list of bracketed examples is noise, not an invariant.
set -uo pipefail

if [ -f .claude/.orchestrator-mode ]; then
  echo "Orchestrator mode is ON (dispatch-only — see .claude/agents/orchestrator/orchestrator-mode.md). Run /orchestrate off to disable."
fi

# the SessionStart source, when the payload carries one; unknown (no jq, no stdin) prints the invariants
source_kind=""
if [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  source_kind=$(jq -r '.source // ""' 2>/dev/null) || source_kind=""
fi
case "$source_kind" in startup | clear) exit 0 ;; esac

# the payload sits beside this hook's directory, also when the hook is reached through a symlink
self="${BASH_SOURCE[0]}"
while [ -L "$self" ]; do
  dir=$(cd "$(dirname "$self")" && pwd -P)
  self=$(readlink "$self")
  case "$self" in /*) ;; *) self="$dir/$self" ;; esac
done
payload="$(cd "$(dirname "$self")/.." 2>/dev/null && pwd -P)/rules/invariants.md"
[ -f "$payload" ] || exit 0

# drop a leading YAML frontmatter block (--- … ---) if there is one
body=$(awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$payload")
[ -n "$body" ] || exit 0
case "$body" in *"[Add your project's"*) exit 0 ;; esac
printf '%s\n' "$body"
exit 0

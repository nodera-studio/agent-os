#!/usr/bin/env bash
# SessionStart(resume|compact) + PreCompact: re-inject the project's non-negotiable invariants so
# long autonomous/agentic runs survive compaction. The payload is rules/invariants.md (frontmatter
# stripped); keep it < ~500 tokens. While it still holds the template's placeholder text the hook
# prints nothing: a list of bracketed examples is noise, not an invariant.
set -uo pipefail

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

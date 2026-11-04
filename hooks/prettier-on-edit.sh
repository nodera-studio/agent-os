#!/usr/bin/env bash
# PostToolUse (Edit|Write): format the edited file with the project's own prettier.
# Silent unless the nearest package.json project both configures prettier (a config file, a
# "prettier" key, or a prettier dependency) and has it installed locally (node_modules/.bin).
# It never installs or downloads anything, and it works with any package manager because it runs
# the local binary directly. A failure is reported through additionalContext, so the turn is never
# interrupted. Yarn PnP projects have no node_modules/.bin and are skipped. Never exits non-zero.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // ""')

case "$file" in
  *.ts | *.tsx | *.js | *.jsx | *.json | *.css | *.scss) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0

# the nearest ancestor holding a package.json
root=$(cd "$(dirname "$file")" 2>/dev/null && pwd -P) || exit 0
while [ ! -f "$root/package.json" ]; do
  [ "$root" != / ] || exit 0
  root=$(dirname "$root")
done

configured=0
for f in "$root"/.prettierrc "$root"/.prettierrc.* "$root"/prettier.config.*; do
  [ -f "$f" ] && configured=1
done
if [ "$configured" = 0 ] && jq -e '.prettier or .dependencies.prettier or .devDependencies.prettier' "$root/package.json" >/dev/null 2>&1; then
  configured=1
fi
[ "$configured" = 1 ] || exit 0
bin="$root/node_modules/.bin/prettier"
[ -x "$bin" ] || exit 0

if ! out=$(cd "$root" && "$bin" --write --ignore-unknown "$file" 2>&1); then
  note="prettier failed on $file (the edit is saved; continuing):
$out"
  jq -n --arg c "$note" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
fi
exit 0

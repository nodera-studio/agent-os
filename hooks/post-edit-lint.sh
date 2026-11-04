#!/usr/bin/env bash
# PostToolUse (Edit|Write): lint or format the edited file, dispatching on its extension after one
# jq parse of the payload. Findings reach Claude in the SAME turn through non-blocking
# additionalContext (PostToolUse stdout on exit 0 is not shown to the model, and decision:"block" can
# halt the turn depending on version), so the turn is never interrupted. The file is already saved.
#   - ts/tsx/js/jsx/json/css/scss: format with the project's own prettier. Silent unless the nearest
#     package.json project both configures prettier (a config file, a "prettier" key, or a prettier
#     dependency) and has it installed locally (node_modules/.bin). It never installs or downloads
#     anything, and it works with any package manager because it runs the local binary directly. Yarn
#     PnP projects have no node_modules/.bin and are skipped.
#   - sh/bash: lint with `shellcheck -S warning -f gcc` (style/info noise is skipped); silent when the
#     tool is not installed.
# Fail-open posture: no jq, an unknown extension or a missing tool is a silent no-op, and the hook
# never exits non-zero.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0 # jq drives parse + output → fail open without it

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // ""')
[ -f "$file" ] || exit 0

# prettier_note <file>: prints the failure text when the local prettier fails; silent otherwise
prettier_note() {
  local f="$1" root cfg configured=0 bin out
  # the nearest ancestor holding a package.json
  root=$(cd "$(dirname "$f")" 2>/dev/null && pwd -P) || return 0
  while [ ! -f "$root/package.json" ]; do
    [ "$root" != / ] || return 0
    root=$(dirname "$root")
  done
  for cfg in "$root"/.prettierrc "$root"/.prettierrc.* "$root"/prettier.config.*; do
    [ -f "$cfg" ] && configured=1
  done
  if [ "$configured" = 0 ] && jq -e '.prettier or .dependencies.prettier or .devDependencies.prettier' "$root/package.json" >/dev/null 2>&1; then
    configured=1
  fi
  [ "$configured" = 1 ] || return 0
  bin="$root/node_modules/.bin/prettier"
  [ -x "$bin" ] || return 0
  if ! out=$(cd "$root" && "$bin" --write --ignore-unknown "$f" 2>&1); then
    printf 'prettier failed on %s (the edit is saved; continuing):\n%s' "$f" "$out"
  fi
}

# shell_note <file>: prints the findings, or nothing when clean or shellcheck is absent
shell_note() {
  local f="$1" findings
  command -v shellcheck >/dev/null 2>&1 || return 0 # not installed → fail open
  findings=$(shellcheck -S warning -f gcc "$f" 2>/dev/null) || true
  [ -z "$findings" ] || printf 'shellcheck (warning+) findings in %s — fix before relying on this script:\n%s' "$f" "$findings"
}

note=""
case "$file" in
  *.ts | *.tsx | *.js | *.jsx | *.json | *.css | *.scss) note=$(prettier_note "$file") ;;
  *.sh | *.bash) note=$(shell_note "$file") ;;
  *) exit 0 ;;
esac

# jq -n builds valid JSON regardless of quotes/newlines in the note
[ -z "$note" ] || jq -n --arg c "$note" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0

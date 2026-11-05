#!/usr/bin/env bash
# Stop hook — learned-rules episodic-fix capture.
#
# On end-of-turn (Claude Code's `Stop` event — there is no SessionEnd event), records one `episodic_fix`
# rule_findings row per changed source file in the PROJECT'S OWN Postgres (DATABASE_URL, through
# scripts/mnemosyne/record-finding.mjs), so the learned-rules distiller has raw evidence of what the agent
# touched. It writes nowhere else: not to the owner's Mnemosyne memory, not to any server.
#
# Posture (mirrors post-edit-lint.sh — warn-don't-block):
#   - ALWAYS exit 0. Capture must NEVER gate the turn. It runs BEFORE any blocking Stop-hook test gate you may
#     add to the Stop array, and its exit 0 can't suppress that gate's exit 2.
#   - Opt-in: LEARNED_RULES_CAPTURE=1 (MNEMOSYNE_CAPTURE=1, the old name, still works), so CI and other
#     contexts' Stop hooks are inert.
#   - Guards stop_hook_active so a stop-hook continuation doesn't re-capture.
#
# Project settings (all optional):
#   LEARNED_RULES_PATHS  git pathspecs to watch, space separated. Default: the whole repository (`.`).
#                        e.g. LEARNED_RULES_PATHS="src lib" or "apps packages"
#   LEARNED_RULES_EXT    extended-regex of file extensions to capture. Default: ts|tsx|js|jsx
#   .claude/learned-rules-categories.txt
#                        one `<shell-glob> <category>` per line (first match wins), e.g.
#                          *billing* billing
#                          src/queue/* queue
#                        Without it, a path is `uncategorized`; the distiller refines the category later.
set -uo pipefail

# Opt-in only.
if [ "${LEARNED_RULES_CAPTURE:-${MNEMOSYNE_CAPTURE:-0}}" != "1" ]; then exit 0; fi

input=$(cat)

# Don't re-capture inside a stop-hook continuation.
if [ "$(echo "$input" | jq -r '.stop_hook_active // false')" = "true" ]; then
  exit 0
fi

# Only capture when source files changed this turn.
paths="${LEARNED_RULES_PATHS:-.}"
ext="${LEARNED_RULES_EXT:-ts|tsx|js|jsx}"
# shellcheck disable=SC2086
changed=$(git status --porcelain --untracked-files=all -- $paths 2>/dev/null | grep -E "\\.($ext)\$" || true)
[ -z "$changed" ] && exit 0

session_id=$(echo "$input" | jq -r '.session_id // ""')
head_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "")
commit_subject=$(git log -1 --pretty=%s 2>/dev/null || echo "")
root="$(git rev-parse --show-toplevel 2>/dev/null)"

# Derive a coarse category from a changed path via the project's own list (see the header).
categorize() {
  local file="$1" pattern category
  if [ -f "$root/.claude/learned-rules-categories.txt" ]; then
    while read -r pattern category; do
      case "$pattern" in '' | '#'*) continue ;; esac
      # shellcheck disable=SC2254
      case "$file" in $pattern) echo "${category:-uncategorized}"; return ;; esac
    done <"$root/.claude/learned-rules-categories.txt"
  fi
  echo "uncategorized"
}

REC="$root/.claude/scripts/mnemosyne/record-finding.mjs"
[ -f "$REC" ] || exit 0

# One finding per distinct changed file (cap at a sane number to stay cheap).
echo "$changed" | awk '{print $2}' | sort -u | head -20 | while IFS= read -r file; do
  [ -z "$file" ] && continue
  category=$(categorize "$file")
  text=${commit_subject:-"uncommitted change to $file"}
  finding=$(jq -nc \
    --arg source "episodic_fix" \
    --arg finding_text "$text" \
    --arg category "$category" \
    --arg file "$file" \
    --arg action "fixed" \
    --arg commit_sha "$head_sha" \
    --arg session_id "$session_id" \
    '{source:$source, finding_text:$finding_text, category:$category, file:$file,
      accepted:null, action:$action, commit_sha:($commit_sha|select(.!="")),
      session_id:($session_id|select(.!=""))}')
  node "$REC" --json "$finding" >/dev/null 2>&1 || true
done

exit 0

#!/bin/bash
# orchestrator-smoke.sh — the orchestrator pack: record-gap.mjs and the mode notice hook (Bash 3.2, no network).
#
# Usage: /bin/bash .claude/scripts/tests/orchestrator-smoke.sh
# record-gap.mjs runs in a throwaway git repo: the first gap creates GapLog.md and gaps.jsonl (nothing is seeded
# by the installer), the second appends a row above the first, pipes in a task are escaped, missing fields fail
# without writing. The notice hook prints only while the .orchestrator-mode marker exists. Needs node and jq.
# Exit 1 on any FAIL.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SCRIPTS="$HERE/.."
HOOKS="$HERE/../../hooks"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/orchestrator-smoke.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }
command -v node >/dev/null 2>&1 || { echo "FAIL: node not installed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed"; exit 1; }

R="$TMP/repo"; mkdir -p "$R"
git init -q "$R"
GAPS="$R/.claude/orchestrator/gaps.jsonl"
LOG="$R/.claude/orchestrator/GapLog.md"
rec() { (cd "$R" && node "$SCRIPTS/orchestrator/record-gap.mjs" "$@" 2>&1); }

[ ! -e "$LOG" ] && ok 'nothing seeds GapLog.md before the first gap' || fail 'GapLog.md exists before the first gap'
OUT="$(rec --json '{"task_summary":"first | task","why_no_fit":"no agent","adhoc_agent_base":"general-purpose","tags":["a","b"]}')"; RC=$?
[ "$RC" -eq 0 ] && ok 'the first gap is recorded' || fail 'first gap' "rc=$RC: $OUT"
[ -f "$LOG" ] && grep -q '^## Open gaps' "$LOG" && grep -q '^## Promoted' "$LOG" && ok 'GapLog.md is created from the scaffold' || fail 'GapLog.md scaffold'
[ "$(wc -l <"$GAPS" | tr -d ' ')" = 1 ] && [ "$(jq -r '.status' "$GAPS")" = open ] && ok 'gaps.jsonl holds one open record' || fail 'gaps.jsonl'
grep -q 'first \\| task' "$LOG" && ok 'a pipe in a value is escaped in the table' || fail 'pipe escape'
rec --json '{"task_summary":"second task","why_no_fit":"still none","adhoc_agent_base":"Explore"}' >/dev/null
[ "$(wc -l <"$GAPS" | tr -d ' ')" = 2 ] && ok 'the second gap appends a line' || fail 'second gap line'
rows="$(grep -c '^| g-' "$LOG")"
[ "$rows" = 2 ] && ok 'both gaps are rows of the open table' || fail 'rows' "$rows"
OUT="$(rec --json '{"task_summary":"x"}')"; RC=$?
[ "$RC" -ne 0 ] && [ "$(wc -l <"$GAPS" | tr -d ' ')" = 2 ] && ok 'a missing required field fails and writes nothing' || fail 'missing field' "rc=$RC: $OUT"
OUT="$(rec)"; RC=$?
[ "$RC" -ne 0 ] && ok 'no --json fails' || fail 'no --json' "$OUT"

N="$TMP/notice"; mkdir -p "$N/.claude"
out="$(cd "$N" && /bin/bash "$HOOKS/orchestrator-mode-notice.sh" </dev/null)"
[ -z "$out" ] && ok 'no marker: the notice hook prints nothing' || fail 'notice without marker' "$out"
: >"$N/.claude/.orchestrator-mode"
out="$(cd "$N" && /bin/bash "$HOOKS/orchestrator-mode-notice.sh" </dev/null)"
case "$out" in "Orchestrator mode is ON"*"/orchestrate off"*) ok 'the marker prints the notice' ;; *) fail 'notice with marker' "$out" ;; esac

[ "$FAILS" -eq 0 ]

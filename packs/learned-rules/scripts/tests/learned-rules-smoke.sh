#!/bin/bash
# learned-rules-smoke.sh — learned-rules-capture.sh against a stub recorder in a throwaway repo (Bash 3.2, no network).
#
# Usage: /bin/bash .claude/scripts/tests/learned-rules-smoke.sh
# Cases: off by default; on with LEARNED_RULES_CAPTURE=1 or the old MNEMOSYNE_CAPTURE=1; the stop_hook_active guard;
# LEARNED_RULES_PATHS and LEARNED_RULES_EXT narrow what is watched; the categories file maps a path; every run exits 0.
# The recorder is a stub that logs its argv, so no Postgres or node is touched. Needs jq and git. Exit 1 on any FAIL.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="$HERE/../../hooks/learned-rules-capture.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/learned-rules-smoke.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git not installed"; exit 1; }
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

R="$TMP/repo"; mkdir -p "$R/.claude/scripts/mnemosyne" "$R/src" "$R/docs"
LOG="$TMP/record.log"
# A stub node: the hook runs `node <record-finding.mjs> --json <finding>`; log the finding and succeed.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/node" <<STUB
#!/bin/sh
shift
[ "\$1" = --json ] && printf '%s\n' "\$2" >>"$LOG"
exit 0
STUB
chmod +x "$TMP/bin/node"
: >"$R/.claude/scripts/mnemosyne/record-finding.mjs"
git -C "$R" init -q
git -C "$R" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m "initial work"
printf 'a\n' >"$R/src/a.ts"; printf 'b\n' >"$R/docs/b.ts"; printf 'c\n' >"$R/src/c.py"

run() { # run <stdin-json> [VAR=value ...]: the hook's exit status; stub log is reset first
  local in="$1"; shift
  : >"$LOG"
  (cd "$R" && env "$@" PATH="$TMP/bin:$PATH" /bin/bash "$HOOK" <<<"$in" >/dev/null 2>&1)
}
count() { grep -c . "$LOG" | tr -d ' '; }

run '{"session_id":"s1"}'; RC=$?
[ "$RC" = 0 ] && [ "$(count)" = 0 ] && ok 'off by default: nothing recorded, exit 0' || fail 'off by default' "rc=$RC n=$(count)"

run '{"session_id":"s1"}' LEARNED_RULES_CAPTURE=1; RC=$?
[ "$RC" = 0 ] && [ "$(count)" = 2 ] && ok 'on: one record per changed ts file (src/a.ts, docs/b.ts), py ignored' || fail 'on' "rc=$RC n=$(count)"
[ "$(jq -r '.category' "$LOG" | sort -u)" = uncategorized ] && ok 'without a categories file every path is uncategorized' || fail 'default category'
[ "$(jq -r '.source' "$LOG" | sort -u)" = episodic_fix ] && [ "$(jq -r '.finding_text' "$LOG" | sort -u)" = "initial work" ] && ok 'records carry the source and the commit subject' || fail 'record shape'

run '{"session_id":"s1"}' MNEMOSYNE_CAPTURE=1
[ "$(count)" = 2 ] && ok 'the old MNEMOSYNE_CAPTURE=1 name still opts in' || fail 'legacy env' "n=$(count)"

run '{"session_id":"s1","stop_hook_active":true}' LEARNED_RULES_CAPTURE=1
[ "$(count)" = 0 ] && ok 'stop_hook_active records nothing' || fail 'stop_hook_active'

run '{"session_id":"s1"}' LEARNED_RULES_CAPTURE=1 LEARNED_RULES_PATHS=src
[ "$(count)" = 1 ] && [ "$(jq -r '.file' "$LOG")" = src/a.ts ] && ok 'LEARNED_RULES_PATHS narrows the watched paths' || fail 'paths' "n=$(count)"

run '{"session_id":"s1"}' LEARNED_RULES_CAPTURE=1 LEARNED_RULES_EXT='py'
[ "$(count)" = 1 ] && [ "$(jq -r '.file' "$LOG")" = src/c.py ] && ok 'LEARNED_RULES_EXT changes the extensions' || fail 'ext' "n=$(count)"

printf '# project categories\nsrc/* backend\n*docs* docs\n' >"$R/.claude/learned-rules-categories.txt"
run '{"session_id":"s1"}' LEARNED_RULES_CAPTURE=1
got="$(jq -r '.file + "=" + .category' "$LOG" | sort | tr '\n' ' ')"
[ "$got" = "docs/b.ts=docs src/a.ts=backend " ] && ok 'the categories file maps paths, first match wins' || fail 'categories' "$got"

rm -f "$R/.claude/scripts/mnemosyne/record-finding.mjs"
run '{"session_id":"s1"}' LEARNED_RULES_CAPTURE=1; RC=$?
[ "$RC" = 0 ] && [ "$(count)" = 0 ] && ok 'no recorder script: silent exit 0' || fail 'no recorder' "rc=$RC"

[ "$FAILS" -eq 0 ]

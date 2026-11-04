#!/bin/bash
# check-refs-smoke.sh — smoke test for .claude/scripts/check-refs.sh (Bash 3.2, no network).
#
# Usage: /bin/bash .claude/scripts/tests/check-refs-smoke.sh
# Cases (each on a throwaway tree): a hit prints file:line and exits 1; no hit exits 0; several needles;
# fixed-string matching (dots and slashes are literal); --exclude-packs; --exclude of a directory, a nested
# path and a file; .git and node_modules skipped; symlinks not followed; usage errors exit 2.
# Exit 1 on any FAIL.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
CHECK="$HERE/../check-refs.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-refs-smoke.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }

T="$TMP/tree"
mkdir -p "$T/agents/x" "$T/packs/p" "$T/.git" "$T/node_modules/m" "$T/docs/old" "$T/real"
printf 'see agents/old/planner.md here\nunrelated\n' >"$T/agents/x/a.md"
printf 'impl-old-name is used\n' >"$T/agents/x/b.md"
printf 'agents/old/planner.md in a pack\n' >"$T/packs/p/c.md"
printf 'agents/old/planner.md in git\n' >"$T/.git/config"
printf 'agents/old/planner.md in a dependency\n' >"$T/node_modules/m/i.js"
printf 'agents/old/planner.md in docs\n' >"$T/docs/old/d.md"
printf 'agents/old/planner.md in real\n' >"$T/real/r.md"
ln -s "$T/real" "$T/linked"
printf 'agentsXold/planner.md only a regex would match\n' >"$T/agents/x/e.md"

# run <args...>: sets OUT, ERR, RC.
run() {
  OUT="$(/bin/bash "$CHECK" --root "$T" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}
expect() { # name want_rc
  if [ "$RC" -eq "$2" ]; then ok "$1"; else fail "$1" "rc=$RC want $2, out: $OUT / $ERR"; fi
}
has() { printf '%s\n' "$OUT" | grep -qF -- "$2" && ok "$1" || fail "$1" "missing '$2' in: $OUT"; }
lacks() { printf '%s\n' "$OUT" | grep -qF -- "$2" && fail "$1" "unexpected '$2' in: $OUT" || ok "$1"; }

run agents/old/planner.md
expect 'hit exits 1' 1
has 'hit is file:line:text' 'agents/x/a.md:1:see agents/old/planner.md here'
printf '%s' "$ERR" | grep -q 'check-refs: [0-9]* reference(s) to 1 needle(s)' && ok 'stderr summary' || fail 'stderr summary' "$ERR"
lacks 'fixed string, not a regex' 'agentsXold'
lacks '.git skipped' '.git/config'
lacks 'node_modules skipped' 'node_modules'
lacks 'symlinked directory not followed' 'linked/'
has 'real directory is found' 'real/r.md:1'

run no-such-name-anywhere
expect 'no hit exits 0' 0
[ -z "$OUT" ] && ok 'no hit prints nothing on stdout' || fail 'no hit prints nothing on stdout' "$OUT"

run no-such-name-anywhere impl-old-name
expect 'several needles, one hits' 1
has 'second needle found' 'agents/x/b.md:1'

run agents/old/planner.md
has 'packs are scanned by default' 'packs/p/c.md'
run --exclude-packs agents/old/planner.md
lacks '--exclude-packs skips packs/' 'packs/'
has '--exclude-packs keeps the rest' 'agents/x/a.md'
run --exclude docs agents/old/planner.md
lacks '--exclude of a directory' 'docs/old/d.md'
run --exclude docs/old agents/old/planner.md
lacks '--exclude of a nested path' 'docs/old/d.md'
has 'a nested exclude keeps siblings' 'agents/x/a.md'
run --exclude agents/x/a.md agents/old/planner.md
lacks '--exclude of a file' 'agents/x/a.md'
has 'a file exclude keeps other files' 'real/r.md'
run --exclude-packs --exclude docs --exclude real --exclude agents impl-old-name
expect 'everything excluded exits 0' 0

run
expect 'no needle exits 2' 2
run --bogus x
expect 'unknown flag exits 2' 2
run --root
expect '--root without a value exits 2' 2
OUT="$(/bin/bash "$CHECK" --root "$TMP/missing" x 2>/dev/null)"; RC=$?
expect 'missing root exits 2' 2
run ''
expect 'empty needle exits 2' 2

[ "$FAILS" -eq 0 ]

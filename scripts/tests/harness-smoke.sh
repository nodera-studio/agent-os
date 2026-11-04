#!/bin/bash
# harness-smoke.sh — run the smoke suites inside a disposable project that carries this checkout as `.claude/`.
#
# Usage: /bin/bash scripts/tests/harness-smoke.sh [--list] [suite-name ...]
# The suites resolve `$REPO_ROOT/.claude/...` and need a git project around the harness, so running
# them from a bare checkout fails. This copies the working tree (tracked plus untracked, uncommitted
# edits included) to <tmp>/project/.claude, commits it on main, and runs each suite from there.
# With no suite names it runs every scripts/tests/*-smoke.sh except itself, in name order. A name is
# the file name without `-smoke.sh` or `.sh`. Bash 3.2, no network. Exit 1 if any suite fails.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SRC="$(cd "$HERE/../.." && pwd -P)"
SELF="$(basename "$0")"

all_suites() {
  local f
  for f in "$HERE"/*-smoke.sh; do
    [ "$(basename "$f")" = "$SELF" ] || basename "$f"
  done
}

if [ "${1:-}" = --list ]; then all_suites; exit 0; fi

SUITES=""
if [ "$#" -eq 0 ]; then
  SUITES="$(all_suites)"
else
  for n in "$@"; do
    n="${n%.sh}"; n="${n%-smoke}"
    [ -f "$HERE/$n-smoke.sh" ] || { echo "FAIL: no such suite: $n" >&2; exit 1; }
    SUITES="$SUITES
$n-smoke.sh"
  done
fi

command -v git >/dev/null 2>&1 || { echo "FAIL: git not installed" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-smoke.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT/.claude"

# Tracked plus untracked-not-ignored files, skipping paths deleted in the working tree.
(cd "$SRC" && git ls-files -co --exclude-standard) | while IFS= read -r f; do
  [ -f "$SRC/$f" ] || continue
  mkdir -p "$PROJECT/.claude/$(dirname "$f")"
  cp -p "$SRC/$f" "$PROJECT/.claude/$f"
done

git -C "$PROJECT" init -q --initial-branch=main
git -C "$PROJECT" add -A
git -C "$PROJECT" -c user.name='Harness smoke' -c user.email='smoke@example.invalid' \
  -c core.hooksPath=/dev/null -c commit.gpgsign=false commit --no-gpg-sign -qm fixture \
  || { echo "FAIL: fixture commit" >&2; exit 1; }

FAILS=0 RAN=0
for s in $SUITES; do
  RAN=$((RAN + 1))
  if (cd "$PROJECT" && /bin/bash ".claude/scripts/tests/$s" >"$TMP/out" 2>&1); then
    echo "ok   $s"
  else
    echo "FAIL $s"
    tail -n 25 "$TMP/out" | sed 's/^/     | /'
    FAILS=$((FAILS + 1))
  fi
done
echo "$RAN suites, $FAILS failed"
[ "$FAILS" -eq 0 ]

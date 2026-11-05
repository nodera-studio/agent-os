#!/bin/bash
# harness-smoke.sh — run the smoke suites inside a disposable project that carries this checkout as `.claude/`.
#
# Usage: /bin/bash scripts/tests/harness-smoke.sh [--list] [suite-name ...]
# The suites resolve `$REPO_ROOT/.claude/...` and need a git project around the harness, so running
# them from a bare checkout fails. This copies the working tree (tracked plus untracked, uncommitted
# edits included) to <tmp>/project/.claude, commits it on main, and runs each suite from there.
# With no suite names it runs every scripts/tests/*-smoke.sh except itself, in name order. A name is
# the file name without `-smoke.sh` or `.sh`. Bash 3.2, no network. Exit 1 if any suite fails.
#
# Pack tests: a pack's own smoke suites (packs/<name>/scripts/tests/*-smoke.sh) are not in the default run.
# HARNESS_SMOKE_PACKS="codex orchestrator" (names separated by spaces or commas, or `all`) copies those packs'
# files into the fixture's .claude/ as if installed and adds their suites to the list and to name lookup.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SRC="$(cd "$HERE/../.." && pwd -P)"
SELF="$(basename "$0")"

# Packs whose files and tests this run includes (opt-in).
PACKS=""
case "${HARNESS_SMOKE_PACKS:-}" in
  "") ;;
  all)
    for m in "$SRC"/packs/*/pack.json; do
      [ -f "$m" ] && PACKS="$PACKS $(basename "$(dirname "$m")")"
    done
    ;;
  *) PACKS="$(printf '%s' "$HARNESS_SMOKE_PACKS" | tr ',' ' ')" ;;
esac
if [ -n "$PACKS" ]; then
  command -v jq >/dev/null 2>&1 || { echo "FAIL: HARNESS_SMOKE_PACKS needs jq" >&2; exit 1; }
  for p in $PACKS; do
    [ -f "$SRC/packs/$p/pack.json" ] || { echo "FAIL: no such pack: $p" >&2; exit 1; }
  done
fi

# Smoke suites the selected packs ship, as bare file names.
pack_suites() {
  local p
  for p in $PACKS; do
    jq -r '.files[] | select(test("^scripts/tests/[^/]*-smoke\\.sh$"))' "$SRC/packs/$p/pack.json" | while IFS= read -r f; do
      basename "$f"
    done
  done
}

all_suites() {
  local f
  for f in "$HERE"/*-smoke.sh; do
    [ "$(basename "$f")" = "$SELF" ] || basename "$f"
  done
  pack_suites
}

if [ "${1:-}" = --list ]; then all_suites; exit 0; fi

SUITES=""
if [ "$#" -eq 0 ]; then
  SUITES="$(all_suites)"
else
  for n in "$@"; do
    n="${n%.sh}"; n="${n%-smoke}"
    if [ ! -f "$HERE/$n-smoke.sh" ] && ! pack_suites | grep -qx "$n-smoke.sh"; then
      echo "FAIL: no such suite: $n (pack suites need HARNESS_SMOKE_PACKS)" >&2; exit 1
    fi
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

# Tracked plus untracked-not-ignored files, skipping paths deleted in the working tree (dangling links are kept).
(cd "$SRC" && git ls-files -co --exclude-standard) | while IFS= read -r f; do
  [ -f "$SRC/$f" ] || [ -L "$SRC/$f" ] || continue
  mkdir -p "$PROJECT/.claude/$(dirname "$f")"
  # A symlink (the plugin directory is all symlinks) is copied as a symlink, not followed.
  cp -pP "$SRC/$f" "$PROJECT/.claude/$f"
done

# Selected packs: their files land in .claude/ exactly where install.sh would put them.
for p in $PACKS; do
  jq -r '.files[]' "$SRC/packs/$p/pack.json" | while IFS= read -r f; do
    mkdir -p "$PROJECT/.claude/$(dirname "$f")"
    cp -p "$SRC/packs/$p/$f" "$PROJECT/.claude/$f"
  done
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
    { grep -a -A1 'FAIL' "$TMP/out" | head -n 40; tail -n 8 "$TMP/out"; } | sed 's/^/     | /'
    FAILS=$((FAILS + 1))
  fi
done
echo "$RAN suites, $FAILS failed"
[ "$FAILS" -eq 0 ]

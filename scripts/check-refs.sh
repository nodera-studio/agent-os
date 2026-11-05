#!/usr/bin/env bash
# check-refs.sh — find dangling inbound references to retired agent, command, skill or script names.
#
# Usage: bash .claude/scripts/check-refs.sh [--root <dir>] [--exclude-packs] [--exclude <path>]... <needle>...
#
# Each needle is a fixed string (a path such as `agents/old/planner.md`, a subagent name such as
# `old-planner`, a command such as `commands/old.md`), matched as a plain substring, case-sensitively,
# in every text file below --root (default: the harness root, the parent of this script's directory).
# `.git` and `node_modules` are always skipped, and symlinks are not followed (so the plugin mirror, which is
# only symlinks, never double-counts). --exclude-packs also skips `packs/`; --exclude <path> skips one more
# path relative to the root (a directory or a file), repeatable.
# Output: one `file:line:text` per hit, then `check-refs: N reference(s) to M needle(s)` on stderr.
# Exit: 0 no hit, 1 at least one hit, 2 bad input.
set -u

die() { echo "check-refs: $*" >&2; exit 2; }
usage() { die "usage: check-refs.sh [--root <dir>] [--exclude-packs] [--exclude <path>]... <needle>..."; }

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$HERE/.."
EXCLUDES=".git node_modules"
NEEDLES=""
NN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a directory"; ROOT="$2"; shift ;;
    --exclude-packs) EXCLUDES="$EXCLUDES packs" ;;
    --exclude) [ $# -ge 2 ] || die "--exclude needs a path"; EXCLUDES="$EXCLUDES $2"; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
  shift
done
while [ $# -gt 0 ]; do
  [ -n "$1" ] || die "empty needle"
  NEEDLES="$NEEDLES
$1"
  NN=$((NN + 1))
  shift
done
[ "$NN" -gt 0 ] || usage
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || die "no such directory: $ROOT"

# One pattern file with a needle per line, matched as fixed strings.
PAT="$(mktemp "${TMPDIR:-/tmp}/check-refs.XXXXXX")" || exit 2
trap 'rm -f "$PAT"' EXIT
printf '%s\n' "${NEEDLES#?}" >"$PAT"

# Directory names go to grep (fast); every exclude is also applied as a path prefix afterwards, which is
# what makes `--exclude sub/dir` and `--exclude file.md` work.
args=""
for e in $EXCLUDES; do
  case "$e" in
    */*|*.*) ;;
    *) args="$args --exclude-dir=$e" ;;
  esac
done

cd "$ROOT" || exit 2
# shellcheck disable=SC2086
HITS="$(grep -rInF $args -f "$PAT" . 2>/dev/null | sed 's|^\./||')"
for e in $EXCLUDES; do
  e="${e%/}"
  HITS="$(printf '%s\n' "$HITS" | awk -v e="$e" -v n="${#e}" '{ f = substr($0, 1, index($0, ":") - 1); if (f == e || substr(f, 1, n + 1) == e "/") next; print }')"
done
if [ -z "$HITS" ]; then
  echo "check-refs: 0 reference(s) to $NN needle(s)" >&2
  exit 0
fi
printf '%s\n' "$HITS"
echo "check-refs: $(printf '%s\n' "$HITS" | wc -l | tr -d ' ') reference(s) to $NN needle(s)" >&2
exit 1

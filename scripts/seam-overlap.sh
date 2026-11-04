#!/usr/bin/env bash
# seam-overlap.sh — list the files two parallel waves both touch (the "shared seams" check).
#
# Usage: bash .claude/scripts/seam-overlap.sh <list-A> <list-B>
#        bash .claude/scripts/seam-overlap.sh --trunk <ref> --branch <A> --branch <B> [--repo <dir>]
#   Two list files, one path per line (a plan's "files to create/modify" section, say), or two
#   branches whose changed files are `git diff --name-only <trunk>...<branch>`.
#
# Both lists are sorted and de-duplicated, then intersected (what `comm -12` does). The script
# reads only; it never changes a branch or a file.
#
# JSON: {overlap:[paths], count, a:{source, count}, b:{source, count}}.
# Exit: 0 no overlap, 1 overlap (the waves share a seam: run in sequence, or merge the first wave
# early, per the auto-mode "Shared seams" rules), 2 bad input.
set -u

die() { echo "seam-overlap: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

TRUNK="" REPO=. BRANCHES="" LISTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --trunk) [ $# -ge 2 ] || die "--trunk needs a ref"; TRUNK="$2"; shift ;;
    --branch) [ $# -ge 2 ] || die "--branch needs a ref"; BRANCHES="$BRANCHES$2
"; shift ;;
    --repo) [ $# -ge 2 ] || die "--repo needs a directory"; REPO="$2"; shift ;;
    -*) die "usage: seam-overlap.sh <list-A> <list-B> | --trunk REF --branch A --branch B" ;;
    *) LISTS="$LISTS$1
" ;;
  esac
  shift
done

TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT
if [ -n "$BRANCHES" ]; then
  [ -z "$LISTS" ] || die "give two lists or two branches, not both"
  [ -n "$TRUNK" ] || die "--branch needs --trunk"
  [ "$(printf '%s' "$BRANCHES" | grep -c .)" = 2 ] || die "give exactly two --branch"
  n=0
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    n=$((n + 1))
    git -C "$REPO" diff --name-only "$TRUNK...$b" 2>/dev/null | sort -u >"$TMP/$n" || die "cannot diff $TRUNK...$b"
    [ -s "$TMP/$n" ] || git -C "$REPO" rev-parse --verify -q "$b^{commit}" >/dev/null || die "no such ref: $b"
    case "$n" in 1) SRC_1="$b" ;; *) SRC_2="$b" ;; esac
  done <<EOS
$BRANCHES
EOS
else
  [ "$(printf '%s' "$LISTS" | grep -c .)" = 2 ] || die "give exactly two list files (or --trunk and two --branch)"
  n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    [ -r "$f" ] || die "cannot read $f"
    sed 's/[[:space:]]*$//; /^$/d' "$f" | sort -u >"$TMP/$n"
    case "$n" in 1) SRC_1="$f" ;; *) SRC_2="$f" ;; esac
  done <<EOS
$LISTS
EOS
fi
comm -12 "$TMP/1" "$TMP/2" >"$TMP/both"
jq -nc --rawfile o "$TMP/both" --arg sa "$SRC_1" --arg sb "$SRC_2" --argjson ca "$(grep -c . "$TMP/1" || true)" --argjson cb "$(grep -c . "$TMP/2" || true)" \
  '($o | split("\n") | map(select(. != ""))) as $p
   | {overlap: $p, count: ($p | length), a: {source: $sa, count: $ca}, b: {source: $sb, count: $cb}}'
[ -s "$TMP/both" ] && exit 1
exit 0

#!/usr/bin/env bash
# stale-reference-scan.sh — list documentation references to things that no longer exist.
#
# Usage: bash .claude/scripts/stale-reference-scan.sh [--root <dir>] [<doc-file>...]
#
# The mechanical "Stale Reference Scanner" of the docs audit. From each doc's code (inline `spans`
# and fenced blocks, never prose) it extracts five kinds of reference and checks each exists:
#   file      a path with a directory and an extension (an optional :line suffix is dropped);
#             found relative to --root or to the doc, and a `.claude/` prefix is also tried
#             without the prefix (the harness itself is the repo root)
#   env       an ALL_CAPS_WITH_UNDERSCORES name; found when some file other than *.md and
#             *.example mentions it, so a variable only the docs and .env.example know is stale.
#             Names defined in a scanned .env.example are checked the same way
#   script    `npm|pnpm|yarn|bun run <name>`; found in some package.json "scripts"
#   make      `make <target>`; found as a Makefile or *.mk target or .PHONY name
#   command   a code span that is exactly `/name`; found as commands/<name>.md or
#             .claude/commands/<name>.md (skipped, and listed under skipped_types, when the
#             project has no commands directory)
# Default doc set (when no file is given): docs/**/*.md, every CLAUDE.md, .claude/agents/README.md,
# and every .env.example, up to six levels deep, skipping node_modules, .git, build output and
# worktrees.
#
# It cannot tell RENAMED from MISSING, so every finding is status MISSING and the model decides.
# JSON: {status, root, files_scanned, references_checked, stale_count, docs_with_stale, stale:
# [{doc, reference, type, status}], skipped_types}. No doc files at all: {"status":"unsupported"}
# and exit 3. Exit: 0 scanned (stale references do not change it), 2 bad input, 3 unsupported.
set -u

die() { echo "stale-reference-scan: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

ROOT=.
FILES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a directory"; ROOT="$2"; shift ;;
    -*) die "usage: stale-reference-scan.sh [--root <dir>] [<doc-file>...]" ;;
    *) FILES="$FILES
$1" ;;
  esac
  shift
done
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || die "no such directory: $ROOT"
cd "$ROOT" || exit 2

# walk <find args>: print matching files below here, skipping dependency, build and worktree dirs.
walk() {
  find . -maxdepth 6 \( -name node_modules -o -name .git -o -name dist -o -name build -o -name .next \
    -o -name coverage -o -name worktrees \) -prune -o -type f \( "$@" \) -print 2>/dev/null | sed 's|^\./||'
}
if [ -z "$FILES" ]; then
  FILES="$(walk \( -path '*/docs/*' -name '*.md' \) -o -name CLAUDE.md -o -name '.env.example' \
    -o -name '*.env.example' -o -path '*/.claude/agents/README.md' | sort)"
fi
FILES="$(printf '%s\n' "$FILES" | sed '/^$/d')"
if [ -z "$FILES" ]; then
  jq -n --arg root "$ROOT" '{status: "unsupported", root: $root, reason: "no documentation files found"}'
  exit 3
fi

TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/refs.tsv"

# code_text <md file>: the file's code spans and fenced-block lines, one per line.
code_text() {
  awk '/^[[:space:]]*```/ { f = !f; next }
       f { print; next }
       { s = $0; while (match(s, /`[^`]+`/)) { print substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH) } }' "$1"
}

N=0
while IFS= read -r doc; do
  [ -f "$doc" ] || continue
  N=$((N + 1))
  case "$doc" in
    *.example)
      grep -oE '^(export[[:space:]]+)?[A-Z][A-Z0-9]*(_[A-Z0-9]+)+=' "$doc" | sed 's/^export[[:space:]]*//; s/=$//' |
        while IFS= read -r v; do printf '%s\tenv\t%s\n' "$doc" "$v"; done >>"$TMP/refs.tsv"
      continue ;;
  esac
  code_text "$doc" >"$TMP/code.txt"
  grep -oE '(npm|pnpm|yarn|bun) run [A-Za-z0-9:_.-]+' "$TMP/code.txt" | awk '{print $3}' |
    while IFS= read -r v; do printf '%s\tscript\t%s\n' "$doc" "$v"; done >>"$TMP/refs.tsv"
  grep -oE '(^|[^A-Za-z0-9_-])make [a-z][A-Za-z0-9_.-]*' "$TMP/code.txt" | awk '{print $NF}' |
    while IFS= read -r v; do printf '%s\tmake\t%s\n' "$doc" "$v"; done >>"$TMP/refs.tsv"
  grep -xE '/[a-z][a-z0-9-]*' "$TMP/code.txt" |
    while IFS= read -r v; do printf '%s\tcommand\t%s\n' "$doc" "$v"; done >>"$TMP/refs.tsv"
  tr -s ' \t' '\n\n' <"$TMP/code.txt" | sed "s/^[\"'(]*//; s/[\"',;:.)]*\$//" >"$TMP/tokens.txt"
  grep -E '^(\./|\.\./)?[A-Za-z0-9_@.-]+(/[A-Za-z0-9_@.-]+)+\.[A-Za-z0-9]+(:[0-9]+(-[0-9]+)?)?$' "$TMP/tokens.txt" |
    grep -vE '^https?:|\*' | sed -E 's/:[0-9]+(-[0-9]+)?$//' |
    while IFS= read -r v; do printf '%s\tfile\t%s\n' "$doc" "$v"; done >>"$TMP/refs.tsv"
  sed 's/=.*//' "$TMP/tokens.txt" | grep -E '^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$' |
    while IFS= read -r v; do printf '%s\tenv\t%s\n' "$doc" "$v"; done >>"$TMP/refs.tsv"
done <<EOF
$FILES
EOF
sort -u "$TMP/refs.tsv" -o "$TMP/refs.tsv"

# What exists.
walk -name package.json | while IFS= read -r p; do
  jq -r '.scripts // {} | keys[]' "$p" 2>/dev/null
done | sort -u >"$TMP/scripts.txt"
{
  walk -name Makefile -o -name GNUmakefile -o -name '*.mk' |
    while IFS= read -r m; do
      sed -n 's/^\([A-Za-z0-9_.\/-][A-Za-z0-9_.\/-]*\)[[:space:]]*:\([^=]\|$\).*/\1/p' "$m"
      sed -n 's/^\.PHONY[[:space:]]*:[[:space:]]*//p' "$m" | tr -s ' ' '\n'
    done
} | sort -u >"$TMP/targets.txt"
CMDDIR=""
for d in .claude/commands commands; do [ -d "$d" ] && { CMDDIR="$d"; break; }; done

SKIPPED='[]'
[ -n "$CMDDIR" ] || SKIPPED='["command"]'

: >"$TMP/missing.tsv"
CHECKED=0
cut -f2,3 "$TMP/refs.tsv" | sort -u >"$TMP/uniq.tsv"
while IFS="$(printf '\t')" read -r type ref; do
  found=0
  case "$type" in
    script) grep -qxF -- "$ref" "$TMP/scripts.txt" && found=1 ;;
    make) grep -qxF -- "$ref" "$TMP/targets.txt" && found=1 ;;
    command)
      if [ -z "$CMDDIR" ]; then continue; fi
      [ -f "$CMDDIR/${ref#/}.md" ] && found=1 ;;
    env)
      grep -rIqw --exclude-dir=node_modules --exclude-dir=.git --exclude='*.md' --exclude='*.example' -e "$ref" . 2>/dev/null && found=1 ;;
    file) continue ;;
  esac
  CHECKED=$((CHECKED + 1))
  [ "$found" = 1 ] || printf '%s\t%s\n' "$type" "$ref" >>"$TMP/missing.tsv"
done <"$TMP/uniq.tsv"

# File references depend on the doc that names them, so they are checked per occurrence.
while IFS="$(printf '\t')" read -r doc type ref; do
  [ "$type" = file ] || continue
  d="$(dirname "$doc")"
  if [ -e "$ref" ] || [ -e "$d/$ref" ] || { case "$ref" in .claude/*) [ -e "${ref#.claude/}" ] ;; *) false ;; esac; }; then
    :
  else
    printf '%s\t%s\t%s\n' "$doc" file "$ref" >>"$TMP/filemissing.tsv"
  fi
done <"$TMP/refs.tsv"
CHECKED=$((CHECKED + $(grep -c "$(printf '\tfile\t')" "$TMP/refs.tsv" || true)))

# Missing non-file references, joined back to every doc that names them.
{
  awk -F '\t' 'NR == FNR { m[$1 "\t" $2] = 1; next } (($2 "\t" $3) in m) { print $0 }' "$TMP/missing.tsv" "$TMP/refs.tsv"
  cat "$TMP/filemissing.tsv" 2>/dev/null
} | sort -u >"$TMP/stale.tsv"

jq -R -s --arg root "$ROOT" --argjson n "$N" --argjson checked "$CHECKED" --argjson skipped "$SKIPPED" '
  [split("\n")[] | select(. != "") | split("\t") | {doc: .[0], type: .[1], reference: .[2], status: "MISSING"}] as $s
  | {status: "ok", root: $root, files_scanned: $n, references_checked: $checked, stale_count: ($s | length),
     docs_with_stale: ($s | map(.doc) | unique | length), stale: $s, skipped_types: $skipped}' "$TMP/stale.tsv"

#!/usr/bin/env bash
# tech-debt-scan.sh — the mechanical groups of the tech-debt audit: code complexity and the
# TODO/marker inventory, as one JSON.
#
# Usage: bash .claude/scripts/tech-debt-scan.sh [--root <dir>] [--dirs "<dir> ..."]
#                                               [--registry <dir>] [--max-lines N] [--limit N]
#   --dirs      source dirs below the root; default: those of apps, packages, src, lib that exist,
#               else the root itself
#   --registry  the tech-debt registry dir; default <root>/.claude/tech-debt, else <root>/tech-debt
#   --max-lines a file longer than this is a splitting candidate (default 400)
#   --limit     most entries kept per list (default 200); every total is still counted in full
#
# Scans *.ts, *.tsx, *.js and *.jsx, skipping node_modules, dist, build, .next, coverage, .git and
# worktrees. Measured: files over --max-lines; `as any`, @ts-ignore and @ts-nocheck; empty catch
# blocks (one line, or a catch whose block holds nothing); console.log/warn/error outside test and
# spec files; approximate deep nesting (a line indented five or more levels, one level being two
# spaces or one tab; per-file counts); and the markers TODO, FIXME, HACK, TEMP, TEMPORARY,
# WORKAROUND, XXX, PARKED: and FUTURE FEATURE: in comments. Each marker carries its owner (from
# `TODO(name)`), whether the comment mentions a plan (a ticket or issue number, or after, once,
# until, when), whether it is intentional (PARKED, FUTURE FEATURE), a category from its path
# (backend, frontend, shared, infrastructure, other) and a registry status: EXISTING when a
# registry file names the marker's file, else NEW. RESOLVED needs reading the code, so it is left
# to the model. Not measured, and listed under `not_measured`: function length and magic numbers,
# which need a parser.
#
# JSON: {status, root, dirs, files_scanned, large_files, type_escapes, empty_catch, console,
# deep_nesting, markers, marker_summary, totals, not_measured}. Without any source file:
# {"status":"unsupported"} and exit 3. Exit: 0 scanned, 2 bad input, 3 unsupported.
set -u

die() { echo "tech-debt-scan: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

ROOT=. DIRS="" REG="" MAXL=400 LIMIT=200
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a directory"; ROOT="$2"; shift ;;
    --dirs) [ $# -ge 2 ] || die "--dirs needs a list"; DIRS="$2"; shift ;;
    --registry) [ $# -ge 2 ] || die "--registry needs a directory"; REG="$2"; shift ;;
    --max-lines) [ $# -ge 2 ] || die "--max-lines needs a number"; MAXL="$2"; shift ;;
    --limit) [ $# -ge 2 ] || die "--limit needs a number"; LIMIT="$2"; shift ;;
    *) die "usage: tech-debt-scan.sh [--root <dir>] [--dirs \"<dir> ...\"] [--registry <dir>] [--max-lines N] [--limit N]" ;;
  esac
  shift
done
case "$MAXL$LIMIT" in '' | *[!0-9]*) die "--max-lines and --limit must be whole numbers" ;; esac
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || die "no such directory: $ROOT"
cd "$ROOT" || exit 2

if [ -z "$DIRS" ]; then
  for d in apps packages src lib; do [ -d "$d" ] && DIRS="$DIRS $d"; done
  DIRS="${DIRS# }"
  [ -n "$DIRS" ] || DIRS=.
fi
if [ -z "$REG" ]; then
  for d in .claude/tech-debt tech-debt; do [ -d "$d" ] && { REG="$d"; break; }; done
fi

TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

: >"$TMP/files0"
for d in $DIRS; do
  [ -d "$d" ] || die "no such source dir: $d"
  find "$d" \( -name node_modules -o -name dist -o -name build -o -name .next -o -name coverage -o -name .git -o -name worktrees \) -prune \
    -o -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) -print0 >>"$TMP/files0"
done
NFILES="$(tr -cd '\0' <"$TMP/files0" | wc -c | tr -d ' ')"
if [ "$NFILES" = 0 ]; then
  jq -n --arg root "$ROOT" --arg dirs "$DIRS" '{status: "unsupported", root: $root, dirs: ($dirs | split(" ")), reason: "no .ts, .tsx, .js or .jsx files"}'
  exit 3
fi
scan() { xargs -0 grep -nIE "$@" <"$TMP/files0" 2>/dev/null | sed 's|^\./||'; } # file:line:text

# grep output "file:line:text" -> [{file, line, text}] (text capped at 200 characters)
to_list() {
  jq -R -s --argjson lim "$LIMIT" '[split("\n")[] | select(. != "")
    | capture("^(?<file>[^:]+):(?<line>[0-9]+):(?<text>.*)$") | {file, line: (.line | tonumber), text: (.text | sub("^\\s+"; "") | .[0:200])}]
    | {total: length, items: .[0:$lim]}'
}
NOTTEST='(\.(spec|test)\.[jt]sx?:|/__tests__/|/tests?/)'

xargs -0 wc -l <"$TMP/files0" 2>/dev/null | grep -v ' total$' | sed 's|^ *||; s|\./||' |
  awk -v m="$MAXL" '$1 > m { n = $1; $1 = ""; sub(/^ /, ""); print n "\t" $0 }' | sort -rn |
  jq -R -s --argjson lim "$LIMIT" '[split("\n")[] | select(. != "") | split("\t") | {file: .[1], lines: (.[0] | tonumber)}]
    | {total: length, items: .[0:$lim]}' >"$TMP/large.json"

scan 'as any|@ts-ignore|@ts-nocheck' | to_list >"$TMP/escapes.json"
scan 'console\.(log|warn|error)' | grep -Ev "$NOTTEST" | to_list >"$TMP/console.json"

# Empty catch: `catch (e) {}` on one line, or a catch whose block is closed on the next line.
{
  scan 'catch[[:space:]]*(\([^)]*\))?[[:space:]]*\{[[:space:]]*\}'
  tr '\0' '\n' <"$TMP/files0" | while IFS= read -r f; do
    awk -v f="${f#./}" '
      prev != "" && $0 ~ /^[[:space:]]*\}/ { print f ":" pn ":" prev }
      { prev = ""; if ($0 ~ /catch[[:space:]]*(\([^)]*\))?[[:space:]]*\{[[:space:]]*$/) { prev = $0; pn = NR } }' "$f"
  done
} | sort -u -t: -k1,1 -k2,2n | to_list >"$TMP/catch.json"

# Deep nesting: lines whose indent is >= 5 levels, counted per file.
scan "^( {10,}|$(printf '\t'){5,})[^ $(printf '\t')]" | cut -d: -f1 | sort | uniq -c | sort -rn | awk '{ print $1 "\t" $2 }' |
  jq -R -s --argjson lim "$LIMIT" '[split("\n")[] | select(. != "") | split("\t") | {file: .[1], deep_lines: (.[0] | tonumber)}]
    | {total: length, method: "indent >= 5 levels (two spaces or one tab each)", items: .[0:$lim]}' >"$TMP/nest.json"

scan '(//|/\*|^[[:space:]]*\*|#)[[:space:]]*(TODO|FIXME|HACK|TEMPORARY|TEMP|WORKAROUND|XXX|PARKED:|FUTURE FEATURE:)([^A-Za-z0-9_]|$)' |
  jq -R -s --arg reg "$(cat "$REG"/*.md 2>/dev/null)" '
    def cat: if test("(^|/)(api|backend|server)(/|$)") then "backend"
             elif test("(^|/)(web|frontend|client|ui)(/|$)") then "frontend"
             elif test("(^|/)shared(/|$)|(^|/)packages/") then "shared"
             elif test("infra|docker|deploy|(^|/)ops(/|$)|\\.github") then "infrastructure" else "other" end;
    [split("\n")[] | select(. != "") | capture("^(?<file>[^:]+):(?<line>[0-9]+):(?<text>.*)$")
      | .file as $f | (.text | capture("(?<m>TODO|FIXME|HACK|TEMPORARY|TEMP|WORKAROUND|XXX|PARKED:|FUTURE FEATURE:)(\\((?<o>[^)]*)\\))?")) as $k
      | {file, line: (.line | tonumber), marker: ($k.m | rtrimstr(":")), owner: ($k.o // null),
         text: (.text | sub("^\\s+"; "") | .[0:200]),
         plan_hint: (.text | test("[A-Z]+-[0-9]+|#[0-9]+|[^A-Za-z](after|once|until|when)[^A-Za-z]")),
         intentional: ($k.m | test("^(PARKED|FUTURE)")), category: (.file | cat),
         registry_status: (if $reg != "" and ($reg | contains($f)) then "EXISTING" else "NEW" end)}]' >"$TMP/markers.json"

jq -n --arg root "$ROOT" --arg dirs "$DIRS" --argjson n "$NFILES" --argjson maxl "$MAXL" \
  --slurpfile large "$TMP/large.json" --slurpfile esc "$TMP/escapes.json" --slurpfile con "$TMP/console.json" \
  --slurpfile ec "$TMP/catch.json" --slurpfile nest "$TMP/nest.json" --slurpfile mk "$TMP/markers.json" --argjson lim "$LIMIT" '
  ($mk[0]) as $m
  | {status: "ok", root: $root, dirs: ($dirs | split(" ")), files_scanned: $n, max_lines: $maxl,
     large_files: $large[0], type_escapes: $esc[0], empty_catch: $ec[0], console: $con[0], deep_nesting: $nest[0],
     markers: {total: ($m | length), items: $m[0:$lim]},
     marker_summary: {by_marker: ($m | group_by(.marker) | map({key: .[0].marker, value: length}) | from_entries),
                      by_category: ($m | group_by(.category) | map({key: .[0].category, value: length}) | from_entries),
                      by_registry_status: ($m | group_by(.registry_status) | map({key: .[0].registry_status, value: length}) | from_entries)},
     totals: {large_files: $large[0].total, type_escapes: $esc[0].total, empty_catch: $ec[0].total,
              console: $con[0].total, markers: ($m | length)},
     not_measured: ["function length over 50 lines", "magic numbers and strings"]}'

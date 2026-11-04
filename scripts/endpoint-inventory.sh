#!/usr/bin/env bash
# endpoint-inventory.sh — list every REST endpoint of a NestJS backend with its auth and validation
# facts, as one JSON. The mechanical "Group 1" of the API audit.
#
# Usage: bash .claude/scripts/endpoint-inventory.sh [--src <dir>] [--prefix <global prefix>]
#   --src     where the *.controller.ts files are; default apps/api/src, else src, else .
#   --prefix  the global route prefix; default: the argument of setGlobalPrefix() in a main.ts under
#             --src, else none
#
# For each method decorated @Get, @Post, @Put, @Patch, @Delete, @Head, @Options or @All it reports
# the HTTP method, the full path (global prefix + @Controller prefix + method path), whether the
# route is public (@Public() on the method or the class) or protected, and for @Body, @Param and
# @Query whether every such parameter names a pipe in the same signature (ZodValidationPipe for a
# body; a Parse*Pipe or ZodValidationPipe for the rest; "n/a" when the route takes none, "no" when
# at least one has no pipe). Also: whether it takes @CurrentUser(), and whether the file mentions
# ENABLE_TEST_HELPERS (a test-only guard). This is a text heuristic over decorators, not a parser:
# validation done by a global pipe, a DTO class or a guard is invisible to it, so "no" means "no
# pipe named here", for the model to confirm in the code. Rate-limit, CORS and pagination checks
# are not covered (they are rules for a semgrep run).
#
# Other frameworks (no *.controller.ts file with @Controller) give {"status":"unsupported"} and
# exit 3. JSON: {status, framework, src, global_prefix, files, endpoints:[{method, path, auth,
# body_validation, param_validation, query_validation, current_user, test_guard, file, line}],
# totals:{endpoints, public, unvalidated_body, unvalidated_param, unvalidated_query}}.
# Exit: 0 scanned, 2 bad input, 3 unsupported.
set -u

die() { echo "endpoint-inventory: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

SRC="" PREFIX="" HAVE_PREFIX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --src) [ $# -ge 2 ] || die "--src needs a directory"; SRC="$2"; shift ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; PREFIX="$2"; HAVE_PREFIX=1; shift ;;
    *) die "usage: endpoint-inventory.sh [--src <dir>] [--prefix <global prefix>]" ;;
  esac
  shift
done
if [ -z "$SRC" ]; then
  for d in apps/api/src src .; do [ -d "$d" ] && { SRC="$d"; break; }; done
fi
[ -d "$SRC" ] || die "no such directory: $SRC"

FILES="$(find "$SRC" \( -name node_modules -o -name dist -o -name .git \) -prune -o -type f -name '*.controller.ts' -print | sort)"
CONTROLLERS=""
for f in $FILES; do grep -q '@Controller[[:space:]]*(' "$f" && CONTROLLERS="$CONTROLLERS $f"; done
if [ -z "$CONTROLLERS" ]; then
  jq -n --arg src "$SRC" '{status: "unsupported", framework: null, src: $src, reason: "no *.controller.ts file with @Controller (only NestJS is supported)"}'
  exit 3
fi

if [ "$HAVE_PREFIX" = 0 ]; then
  MAIN="$(find "$SRC" \( -name node_modules -o -name dist \) -prune -o -type f -name main.ts -print | head -n 1)"
  [ -z "$MAIN" ] || PREFIX="$(sed -n "s/.*setGlobalPrefix[[:space:]]*([[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p" "$MAIN" | head -n 1)"
fi

TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/rows.tsv"
for f in $CONTROLLERS; do
  TG=0
  grep -q 'ENABLE_TEST_HELPERS' "$f" && TG=1
  awk -v file="$f" -v gp="$PREFIX" -v tg="$TG" '
    function str(s) { if (match(s, /[\047"][^\047"]*[\047"]/)) return substr(s, RSTART + 1, RLENGTH - 2); return "" }
    function ctl(s,   t) {
      t = substr(s, index(s, "@Controller"))
      if (match(t, /path[ \t]*:[ \t]*[\047"][^\047"]*[\047"]/)) return str(substr(t, RSTART + 4))
      return str(t)
    }
    # validated(blk, tag, pipe-regex): "n/a" without the tag, "yes" when every such parameter names a pipe
    function validated(blk, tag, re,   n, parts, i, seg) {
      n = split(blk, parts, tag)
      if (n < 2) return "n/a"
      for (i = 2; i <= n; i++) { seg = parts[i]; sub(/@.*/, "", seg); if (seg !~ re) return "no" }
      return "yes"
    }
    function join(a, b, c,   p) {
      p = "/" a "/" b "/" c; gsub(/\/+/, "/", p); if (length(p) > 1) sub(/\/$/, "", p); return p
    }
    function emit(   auth, cu) {
      auth = (blk ~ /@Public[ \t]*\(/ || classpre ~ /@Public[ \t]*\(/) ? "public" : "protected"
      cu = (blk ~ /@CurrentUser[ \t]*\(/) ? "true" : "false"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", method, join(gp, prefix, mpath), auth,
        validated(blk, "@Body[ \t]*\\(", "ZodValidationPipe"), validated(blk, "@Param[ \t]*\\(", "(Parse[A-Za-z]*Pipe|ZodValidationPipe)"),
        validated(blk, "@Query[ \t]*\\(", "(Parse[A-Za-z]*Pipe|ZodValidationPipe)"), cu, (tg == 1 ? "true" : "false"), file, mline
    }
    collecting { blk = blk "\n" $0; if ($0 ~ /\{[ \t]*$/) { emit(); collecting = 0; pre = "" } ; next }
    /@Controller[ \t]*\(/ { prefix = ctl($0); classpre = pre; pre = ""; next }
    /^[ \t]*(export[ \t]+)?(default[ \t]+)?(abstract[ \t]+)?class[ \t]/ { classpre = classpre "\n" pre; pre = ""; next }
    match($0, /@(Get|Post|Put|Patch|Delete|Head|Options|All)[ \t]*\(/) {
      method = toupper(substr($0, RSTART + 1, RLENGTH - 2)); sub(/[ \t]*\(.*/, "", method)
      mpath = str(substr($0, RSTART + RLENGTH)); mline = NR; blk = pre "\n" $0; collecting = 1; next
    }
    /^[ \t]*@/ { pre = pre "\n" $0; next }
    /^(  |\t)\}[ \t]*$/ { pre = "" }
  ' "$f" >>"$TMP/rows.tsv"
done

jq -R -s --arg src "$SRC" --arg gp "$PREFIX" --argjson n "$(printf '%s\n' $CONTROLLERS | grep -c .)" '
  [split("\n")[] | select(. != "") | split("\t")
    | {method: .[0], path: .[1], auth: .[2], body_validation: .[3], param_validation: .[4], query_validation: .[5],
       current_user: (.[6] == "true"), test_guard: (.[7] == "true"), file: .[8], line: (.[9] | tonumber)}] as $e
  | {status: "ok", framework: "nestjs", src: $src, global_prefix: $gp, files: $n, endpoints: $e,
     totals: {endpoints: ($e | length), public: ($e | map(select(.auth == "public")) | length),
              unvalidated_body: ($e | map(select(.body_validation == "no")) | length),
              unvalidated_param: ($e | map(select(.param_validation == "no")) | length),
              unvalidated_query: ($e | map(select(.query_validation == "no")) | length)}}' "$TMP/rows.tsv"

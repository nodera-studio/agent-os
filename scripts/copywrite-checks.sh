#!/usr/bin/env bash
# copywrite-checks.sh — the mechanical gates of the copywriting pipeline, one subcommand each, each
# printing one JSON object {"gate": ..., "ok": true|false, ...}.
#
# Usage: bash .claude/scripts/copywrite-checks.sh <gate> [options]
#   dash        --old S --new S
#               House style: a proposed string may not add an em dash (U+2014) or an en dash (U+2013)
#               that the old string did not have (compared per character, by count).
#   icu         --old S --new S [--resolve-from DIR]
#               An old string with an ICU plural/select/selectordinal must stay structurally the same
#               (@formatjs/icu-messageformat-parser, resolved from DIR, default the cwd). Any other
#               old string passes without loading the parser.
#   babel       --file F [--resolve-from DIR]
#               A .tsx, .jsx or .mdx file must still parse (@babel/parser, parse only, never the
#               generator). Other extensions are skipped.
#   diacritics  --class CHARS --before-file F --after-file F
#               The count of characters from CHARS (for example the locale's diacritics) must not
#               drop between the source and the post-edit file.
#   parity      --a F --b F [--keys k1,k2]
#               Two locale message files (JSON) hold the same keys (dotted paths); with --keys, only
#               those keys must exist in both.
#   glossary    --terms F --text F
#               Brand terms keep their canonical spelling: --terms is the glossary (a markdown table
#               whose first three columns are the term and its locale spellings, as in
#               brand-terms.md.template; else one term per line, # comments ignored); any
#               case-insensitive whole-word match in the text that is not one of the row's spellings
#               is a violation.
# An option value written @path is read from that file (for long or multi-line strings).
#
# The gates only measure; reverting an edit, rejecting a finding and writing the report stay with
# the orchestrator. Exit: 0 the gate passed (or was skipped), 1 it failed, 2 bad input, 3 the gate
# cannot run here (node, or the parser package, is missing) and prints "status":"unsupported".
set -u

die() { echo "copywrite-checks: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"
[ $# -ge 1 ] || die "usage: copywrite-checks.sh <dash|icu|babel|diacritics|parity|glossary> [options]"
GATE="$1"
shift

OLD="" NEW="" FILE="" FROM="" CLASS="" BEFORE="" AFTER="" A="" B="" KEYS="" TERMS="" TEXT=""
val() { # val <option> <value>: the value, or the contents of the file named by @path
  case "$2" in @*) [ -f "${2#@}" ] || die "$1: no such file: ${2#@}"; cat "${2#@}" ;; *) printf '%s' "$2" ;; esac
}
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "$1 needs a value"
  case "$1" in
    --old) OLD="$(val "$1" "$2")" ;;
    --new) NEW="$(val "$1" "$2")" ;;
    --file) FILE="$2" ;;
    --resolve-from) FROM="$2" ;;
    --class) CLASS="$(val "$1" "$2")" ;;
    --before-file) BEFORE="$2" ;;
    --after-file) AFTER="$2" ;;
    --a) A="$2" ;;
    --b) B="$2" ;;
    --keys) KEYS="$2" ;;
    --terms) TERMS="$2" ;;
    --text) TEXT="$2" ;;
    *) die "unknown option: $1" ;;
  esac
  shift 2
done
FROM="${FROM:-$(pwd)}"

finish() { # finish <json>: print it, exit by its .ok
  printf '%s\n' "$1"
  [ "$(printf '%s' "$1" | jq -r '.ok')" = true ] && exit 0
  exit 1
}
need_node() {
  command -v node >/dev/null 2>&1 && return 0
  jq -nc --arg g "$GATE" '{gate: $g, ok: false, status: "unsupported", reason: "node is not installed"}'
  exit 3
}
# node_gate <script>: run it with OLD, NEW, FILE, FROM in the environment; prints its JSON line.
node_gate() { OLD="$OLD" NEW="$NEW" FILE="$FILE" FROM="$FROM" node -e "$1"; }

case "$GATE" in
  dash)
    finish "$(jq -nc --arg old "$OLD" --arg new "$NEW" '
      def n($s; $c): [$s | explode[] | select(. == $c)] | length;
      [{c: 8212, name: "em dash"}, {c: 8211, name: "en dash"}] as $d
      | [$d[] | select(n($new; .c) > n($old; .c)) | .name] as $bad
      | {gate: "dash", ok: ($bad | length == 0), introduced: $bad}')" ;;

  icu)
    if ! printf '%s' "$OLD" | grep -Eq '\{[^}]+,[[:space:]]*(plural|select|selectordinal)'; then
      finish '{"gate":"icu","ok":true,"skipped":"no ICU plural or select in the old string"}'
    fi
    need_node
    OUT="$(node_gate '
      const { createRequire } = require("node:module");
      const path = require("node:path");
      let P;
      try { P = createRequire(path.join(process.env.FROM, "noop.js"))("@formatjs/icu-messageformat-parser"); }
      catch (e) { console.log(JSON.stringify({ gate: "icu", ok: false, status: "unsupported", reason: "@formatjs/icu-messageformat-parser does not resolve from " + process.env.FROM })); process.exit(3); }
      try {
        const r = P.isStructurallySame(P.parse(process.env.OLD, { requiresOtherClause: true }), P.parse(process.env.NEW, { requiresOtherClause: true }));
        console.log(JSON.stringify({ gate: "icu", ok: r.success === true, reason: r.error ? r.error.message : null }));
      } catch (e) { console.log(JSON.stringify({ gate: "icu", ok: false, reason: "Parse failure: " + e.message })); }
    ')"
    rc=$?
    [ -n "$OUT" ] || die "the ICU check printed nothing"
    [ "$rc" = 3 ] && { printf '%s\n' "$OUT"; exit 3; }
    finish "$OUT" ;;

  babel)
    [ -f "$FILE" ] || die "babel needs --file <existing file>"
    case "$FILE" in
      *.tsx | *.jsx | *.mdx) ;;
      *) finish "$(jq -nc --arg f "$FILE" '{gate: "babel", ok: true, skipped: "not a .tsx, .jsx or .mdx file", file: $f}')" ;;
    esac
    need_node
    OUT="$(node_gate '
      const { createRequire } = require("node:module");
      const path = require("node:path");
      const fs = require("node:fs");
      let parser;
      try { parser = createRequire(path.join(process.env.FROM, "noop.js"))("@babel/parser"); }
      catch (e) { console.log(JSON.stringify({ gate: "babel", ok: false, status: "unsupported", reason: "@babel/parser does not resolve from " + process.env.FROM })); process.exit(3); }
      try {
        parser.parse(fs.readFileSync(process.env.FILE, "utf8"), { sourceType: "module", plugins: ["typescript", "jsx"], errorRecovery: false });
        console.log(JSON.stringify({ gate: "babel", ok: true, file: process.env.FILE }));
      } catch (e) { console.log(JSON.stringify({ gate: "babel", ok: false, file: process.env.FILE, reason: e.message })); }
    ')"
    rc=$?
    [ -n "$OUT" ] || die "the Babel check printed nothing"
    [ "$rc" = 3 ] && { printf '%s\n' "$OUT"; exit 3; }
    finish "$OUT" ;;

  diacritics)
    [ -n "$CLASS" ] && [ -f "$BEFORE" ] && [ -f "$AFTER" ] || die "diacritics needs --class, --before-file and --after-file"
    # jq counts code points, so the result does not depend on the locale of this shell.
    count() { jq -Rs --arg c "$CLASS" '($c | explode) as $cs | [explode[] | select(. as $x | $cs | any(. == $x))] | length' "$1"; }
    finish "$(jq -nc --argjson b "$(count "$BEFORE")" --argjson a "$(count "$AFTER")" \
      '{gate: "diacritics", ok: ($a >= $b), before: $b, after: $a}')" ;;

  parity)
    [ -f "$A" ] && [ -f "$B" ] || die "parity needs --a and --b (existing JSON files)"
    jq -e . "$A" >/dev/null 2>&1 || die "not valid JSON: $A"
    jq -e . "$B" >/dev/null 2>&1 || die "not valid JSON: $B"
    keys() { jq -c '[paths(scalars) | map(tostring) | join(".")]' "$1"; }
    finish "$(jq -nc --argjson a "$(keys "$A")" --argjson b "$(keys "$B")" --arg only "$KEYS" '
      ($only | split(",") | map(select(. != ""))) as $o
      | (if ($o | length) > 0 then $o else ($a + $b | unique) end) as $scope
      | [$scope[] | select(. as $k | ($a | index($k)) == null and ($b | index($k)) != null)] as $mia
      | [$scope[] | select(. as $k | ($b | index($k)) == null and ($a | index($k)) != null)] as $mib
      | [$scope[] | select(. as $k | ($a | index($k)) == null and ($b | index($k)) == null)] as $none
      | {gate: "parity", ok: (($mia + $mib + $none) | length == 0), missing_in_a: $mia, missing_in_b: ($mib + $none)}')" ;;

  glossary)
    [ -f "$TERMS" ] && [ -f "$TEXT" ] || die "glossary needs --terms and --text (existing files)"
    ROWS="$(mktemp)" || die "cannot create a temp file"
    trap 'rm -f "$ROWS"' EXIT
    if grep -q '^|' "$TERMS"; then
      grep '^|' "$TERMS" | grep -Ev '^\|[[:space:]:-]+\|' | sed '1d' | awk -F '|' '
        { out = ""; for (i = 2; i <= 4 && i <= NF; i++) { c = $i; gsub(/`/, "", c); gsub(/^[ \t]+|[ \t]+$/, "", c)
            if (c != "" && c !~ /^\[/) out = out (out == "" ? "" : "\t") c }
          if (out != "") print out }' >"$ROWS"
    else
      grep -Ev '^[[:space:]]*(#|$)' "$TERMS" >"$ROWS"
    fi
    VIOL="$(mktemp)" || die "cannot create a temp file"
    trap 'rm -f "$ROWS" "$VIOL"' EXIT
    while IFS= read -r row; do
      OLDIFS="$IFS"; IFS="$(printf '\t')"
      # shellcheck disable=SC2086  # split the tab-separated spellings
      set -- $row
      IFS="$OLDIFS"
      for form in "$@"; do
        grep -oiFw -- "$form" "$TEXT" 2>/dev/null | sort -u | while IFS= read -r hit; do
          okform=0
          for f2 in "$@"; do [ "$hit" = "$f2" ] && okform=1; done
          [ "$okform" = 1 ] || jq -nc --arg t "$1" --arg h "$hit" --arg e "$row" '{term: $t, found: $h, expected: ($e | split("\t"))}'
        done
      done
    done <"$ROWS" | sort -u >"$VIOL"
    finish "$(jq -sc '{gate: "glossary", ok: (length == 0), violations: .}' "$VIOL")" ;;

  *) die "unknown gate: $GATE (dash, icu, babel, diacritics, parity, glossary)" ;;
esac

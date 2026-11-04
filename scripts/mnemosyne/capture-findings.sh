#!/usr/bin/env bash
# capture-findings.sh — the one structured-capture step of the review gates: normalise a review's
# finding outcomes and hand them to the learned-rules ledger (record-finding.mjs), best effort.
#
# Usage: bash .claude/scripts/mnemosyne/capture-findings.sh --session <id> [--source <name>]
#          [--engine <name>] [--commit <sha>] [--input <file>|-] [--dry-run]
#   --session  a stable id for this run (the review scope slug plus the date is fine); required
#   --source   where the findings come from (default `review`; the lean reviewer and the
#              synthesizer each pass their own name)
#   --engine   the engine for records that do not carry one (default `claude`)
#   --commit   the commit sha under review (default: HEAD of the current checkout, if any)
#   --input    findings as a JSON array or one JSON object per line; default `-` (stdin)
#   --dry-run  print the normalised records (one JSON object per line) and send nothing
#
# This replaces the two "keep identical" copies of the structured-capture block in the lean
# reviewer and the synthesizer. Each input record may carry: finding (or finding_text, text,
# description), category, file, engine, action (must_fix | note | dismissed) or must_fix (boolean),
# and pre_existing (or preexisting, boolean). Per record:
#   - pre-existing findings are skipped (they are not this branch's evidence), and so are records
#     with no finding text;
#   - action is the given one if valid, else must_fix when `must_fix` is true, else note;
#     accepted is true exactly for must_fix;
#   - category defaults to uncategorised; file loses a leading ./ and a :line suffix; the text is
#     whitespace-collapsed and cut to 2000 characters.
# The records go to `record-finding.mjs --batch -`, which dedupes on (session, text, file) and needs
# DATABASE_URL (the project's own Postgres, see docs/LearnedRulesLoop.md). MNEMOSYNE_RECORD_CMD
# replaces that command (used by the smoke test).
#
# Capture is bookkeeping: it never gates a review and never edits product code. Whatever goes wrong
# (no DATABASE_URL, no node, the ledger down) is reported in the JSON `status` (recorded, dry-run,
# skipped or failed) with a `reason`, and the exit status stays 0. Exit 2 only for a usage error
# (no --session) or a missing jq.
#
# JSON: {status, reason, session_id, source, captured, skipped_pre_existing, dropped_empty}.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
die() { echo "capture-findings: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

SESSION="" SOURCE=review ENGINE=claude COMMIT="" INPUT=- DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --session) [ $# -ge 2 ] || die "--session needs an id"; SESSION="$2"; shift ;;
    --source) [ $# -ge 2 ] || die "--source needs a name"; SOURCE="$2"; shift ;;
    --engine) [ $# -ge 2 ] || die "--engine needs a name"; ENGINE="$2"; shift ;;
    --commit) [ $# -ge 2 ] || die "--commit needs a sha"; COMMIT="$2"; shift ;;
    --input) [ $# -ge 2 ] || die "--input needs a file or -"; INPUT="$2"; shift ;;
    --dry-run) DRY=1 ;;
    *) die "usage: capture-findings.sh --session ID [--source S] [--engine E] [--commit SHA] [--input FILE|-] [--dry-run]" ;;
  esac
  shift
done
[ -n "$SESSION" ] || die "--session is required"
[ -n "$COMMIT" ] || COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)"

TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT
summary() { # summary <status> <reason> <captured>
  jq -nc --arg s "$1" --arg r "$2" --argjson c "$3" --arg sid "$SESSION" --arg src "$SOURCE" \
    --argjson pre "${PRE:-0}" --argjson empty "${EMPTY:-0}" \
    '{status: $s, reason: (if $r == "" then null else $r end), session_id: $sid, source: $src, captured: $c,
      skipped_pre_existing: $pre, dropped_empty: $empty}'
  exit 0
}
PRE=0 EMPTY=0

if [ "$INPUT" = - ]; then cat >"$TMP/in"; else [ -r "$INPUT" ] && cat "$INPUT" >"$TMP/in" || summary failed "cannot read $INPUT" 0; fi
# a JSON array, or one object per line
jq -c 'if type == "array" then .[] else . end | select(type == "object")' "$TMP/in" >"$TMP/objs" 2>/dev/null || summary failed "the input is not JSON" 0

jq -c --arg session "$SESSION" --arg source "$SOURCE" --arg engine "$ENGINE" --arg commit "$COMMIT" '
  def text: (.finding // .finding_text // .text // .description // "") | tostring | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "") | .[0:2000];
  (.pre_existing // .preexisting // false) as $pre
  | text as $t
  | (if (.action // "") | IN("must_fix", "note", "dismissed") then .action elif (.must_fix // false) == true then "must_fix" else "note" end) as $a
  | {pre: $pre, empty: ($t == ""), rec: {source: $source, engine: (.engine // $engine), finding_text: $t,
      category: ((.category // "uncategorised") | tostring | ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-"; "") | sub("-$"; "") | if . == "" then "uncategorised" else . end),
      file: ((.file // null) | if . == null then null else tostring | sub("^\\./"; "") | sub(":[0-9]+(-[0-9]+)?$"; "") end),
      accepted: ($a == "must_fix"), action: $a, commit_sha: (if $commit == "" then null else $commit end), session_id: $session}}' "$TMP/objs" >"$TMP/norm"

PRE="$(jq -s '[.[] | select(.pre)] | length' "$TMP/norm")"
EMPTY="$(jq -s '[.[] | select(.pre | not) | select(.empty)] | length' "$TMP/norm")"
jq -c 'select((.pre | not) and (.empty | not)) | .rec' "$TMP/norm" >"$TMP/records"
N="$(grep -c . "$TMP/records" || true)"

if [ "$DRY" = 1 ]; then
  cat "$TMP/records"
  exit 0
fi
[ "$N" -gt 0 ] || summary skipped "no findings to record" 0
CMD="${MNEMOSYNE_RECORD_CMD:-}"
if [ -z "$CMD" ]; then
  [ -n "${DATABASE_URL:-}" ] || summary skipped "DATABASE_URL is not set (no learned-rules pipeline in this project)" 0
  command -v node >/dev/null 2>&1 || summary skipped "node is not installed" 0
  [ -f "$HERE/record-finding.mjs" ] || summary failed "record-finding.mjs is missing next to this script" 0
  CMD="node '$HERE/record-finding.mjs'"
fi
if bash -c "$CMD --batch -" <"$TMP/records" >"$TMP/rec.out" 2>"$TMP/rec.err"; then
  summary recorded "" "$N"
else
  summary failed "the recording script failed: $(head -c 300 "$TMP/rec.err" | tr '\n' ' ')" 0
fi

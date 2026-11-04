#!/usr/bin/env bash
# poll-pr.sh — one quiet poll cycle of a PR: print only what is new since the last cycle.
#
# Usage: bash .claude/scripts/poll-pr.sh <pr-number> [--repo <owner/repo>] [--state <state-file>]
#                                        [--no-advance] [--always] [--max-body N]
#   --repo       default: the repo of the current checkout (gh's {owner}/{repo})
#   --state      the auto-mode state file whose "## Poll cursors" section holds this PR's cursor;
#                default <main checkout>/.claude/auto-mode/state.md. Without a readable file there
#                is no cursor: every cycle then reports everything, and cursor.persisted is false
#   --no-advance look without moving the cursor
#   --always     print the JSON even when nothing is new (exit 0); default: print nothing
#   --max-body   cut each comment body to N characters (default 1500)
#
# Each cycle reads, with GET requests only, the PR's inline review comments, issue comments and
# reviews, and its checks (`gh pr checks`). New = created after the cursor line
#   - PR #N last-seen comment: <ISO>
# A review with an empty body and state COMMENTED is skipped (its inline comments arrive on their
# own). Checks have no timestamp, so their cursor is a signature of every check's name and bucket
#   - PR #N last-seen checks: <signature>
# and they are printed only when the signature changed. The cursor lines are rewritten in the state
# file after a cycle that printed (create the line when missing), so a quiet cycle costs no tokens.
#
# This script never posts, resolves, merges, pushes or edits the PR; bot commands such as
# "@coderabbitai resolve" stay with the caller.
#
# JSON: {pr, new_comments:[{kind, id, user, bot, created_at, path, line, state, url, body}],
# checks:{changed, all_green, pass, fail, pending, skipping, failing[], pending_names[]},
# clean (no new comment and every check passed), cursor:{comment, checks, persisted}}. checks.changed
# is false (and the lists empty) when the signature matched.
# Exit: 0 something new was printed (or --always), 1 quiet (stdout empty), 2 bad input, 3 unsupported
# (gh is not installed).
set -u

die() { echo "poll-pr: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

PR="" REPO="" STATE="" ADVANCE=1 ALWAYS=0 MAXB=1500
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die "--repo needs owner/repo"; REPO="$2"; shift ;;
    --state) [ $# -ge 2 ] || die "--state needs a file"; STATE="$2"; shift ;;
    --max-body) [ $# -ge 2 ] || die "--max-body needs a number"; MAXB="$2"; shift ;;
    --no-advance) ADVANCE=0 ;;
    --always) ALWAYS=1 ;;
    -*) die "usage: poll-pr.sh <pr-number> [--repo R] [--state FILE] [--no-advance] [--always] [--max-body N]" ;;
    *) [ -z "$PR" ] || die "one PR number only"; PR="$1" ;;
  esac
  shift
done
case "$PR" in '' | *[!0-9]*) die "the PR number must be a whole number" ;; esac
case "$MAXB" in '' | *[!0-9]*) die "--max-body must be a whole number" ;; esac
command -v gh >/dev/null 2>&1 || { jq -nc '{status: "unsupported", reason: "gh is not installed"}'; exit 3; }
RFLAG=""
if [ -z "$REPO" ]; then
  REPO='{owner}/{repo}' # gh fills the placeholders from the current checkout
else
  case "$REPO" in */*) RFLAG="-R $REPO" ;; *) die "--repo must be owner/repo" ;; esac
fi

if [ -z "$STATE" ]; then
  COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -z "$COMMON" ] || STATE="$(cd "$COMMON/.." && pwd -P)/.claude/auto-mode/state.md"
fi
PERSIST=false
[ -n "$STATE" ] && [ -r "$STATE" ] && [ -w "$STATE" ] && PERSIST=true

cursor_line() { # cursor_line <label>: the value of "- PR #N last-seen <label>:" or empty
  [ "$PERSIST" = true ] || return 0
  sed -n "s/^- PR #$PR last-seen $1:[[:space:]]*//p" "$STATE" | head -n 1
}
CUR_C="$(cursor_line comment)"
CUR_S="$(cursor_line checks)"
SINCE="${CUR_C:-1970-01-01T00:00:00Z}"

TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT
# api <name> <path>: GET the paginated list into $TMP/<name>.json; a gh failure is an error, never "nothing new".
api() {
  gh api --paginate "repos/$REPO/$2" >"$TMP/$1.raw" 2>/dev/null || die "gh api failed for PR #$PR $1 (is it in $REPO, and is gh logged in?)"
  jq -s 'add // []' "$TMP/$1.raw" >"$TMP/$1.json" 2>/dev/null || die "unreadable gh api output for PR #$PR $1"
}
api inline "pulls/$PR/comments"
api issue "issues/$PR/comments"
api reviews "pulls/$PR/reviews"
# gh pr checks exits non-zero for failing or pending checks and when there are none; the JSON is what counts.
# shellcheck disable=SC2086  # RFLAG is "-R owner/repo" or empty
CHECKS="$(gh pr checks "$PR" $RFLAG --json name,bucket 2>/dev/null)"
printf '%s' "$CHECKS" | jq -e 'type == "array"' >/dev/null 2>&1 || CHECKS='[]'

jq -n --arg since "$SINCE" --argjson max "$MAXB" --slurpfile i "$TMP/inline.json" --slurpfile c "$TMP/issue.json" --slurpfile r "$TMP/reviews.json" '
  def cut: if . == null then "" else .[0:$max] end;
  ([$i[0][] | {kind: "inline", id, user: .user.login, bot: (.user.type == "Bot"), created_at, path, line: (.line // .original_line), state: null, url: .html_url, body: (.body | cut)}]
   + [$c[0][] | {kind: "issue", id, user: .user.login, bot: (.user.type == "Bot"), created_at, path: null, line: null, state: null, url: .html_url, body: (.body | cut)}]
   + [$r[0][] | select((.body // "") != "" or .state != "COMMENTED") | {kind: "review", id, user: .user.login, bot: (.user.type == "Bot"), created_at: .submitted_at, path: null, line: null, state: .state, url: .html_url, body: (.body | cut)}]
  ) | map(select(.created_at != null and .created_at > $since)) | sort_by(.created_at)' >"$TMP/new.json"

SIG="$(printf '%s' "$CHECKS" | jq -r 'sort_by(.name) | map(.name + ":" + .bucket) | join("\n")' | cksum | cut -d' ' -f1)"
[ "$CHECKS" != '[]' ] || SIG="none"
CHANGED=false
[ "$SIG" = "$CUR_S" ] || CHANGED=true
NEWC="$(jq length "$TMP/new.json")"
NEXT_C="$(jq -r --arg cur "$SINCE" '(map(.created_at) | max) // $cur' "$TMP/new.json")"

OUT="$(jq -n --argjson pr "$PR" --slurpfile n "$TMP/new.json" --argjson checks "$CHECKS" --argjson changed "$CHANGED" --arg sig "$SIG" \
  --arg nc "$NEXT_C" --argjson persisted "$PERSIST" '
  ($checks | map(select(.bucket == "pass")) | length) as $p | ($checks | map(select(.bucket == "fail" or .bucket == "cancel")) | length) as $f
  | ($checks | map(select(.bucket == "pending")) | length) as $q | ($checks | map(select(.bucket == "skipping")) | length) as $s
  | {pr: $pr, new_comments: $n[0],
     checks: {changed: $changed, all_green: ($f == 0 and $q == 0 and ($checks | length) > 0), pass: $p, fail: $f, pending: $q, skipping: $s,
              failing: (if $changed then [$checks[] | select(.bucket == "fail" or .bucket == "cancel") | .name] else [] end),
              pending_names: (if $changed then [$checks[] | select(.bucket == "pending") | .name] else [] end)},
     clean: (($n[0] | length) == 0 and $f == 0 and $q == 0 and ($checks | length) > 0),
     cursor: {comment: $nc, checks: $sig, persisted: $persisted}}')"

set_cursor() { # set_cursor <label> <value>: rewrite or add the cursor line in the state file
  local label="$1" line="- PR #$PR last-seen $1: $2"
  [ "$PERSIST" = true ] || return 0
  if grep -q "^- PR #$PR last-seen $label:" "$STATE"; then
    awk -v p="- PR #$PR last-seen $label:" -v l="$line" 'index($0, p) == 1 { print l; next } { print }' "$STATE" >"$TMP/state.new"
  elif grep -q '^## Poll cursors' "$STATE"; then
    awk -v l="$line" '{ print } /^## Poll cursors/ { print l }' "$STATE" >"$TMP/state.new"
  else
    { cat "$STATE"; printf '\n## Poll cursors\n\n%s\n' "$line"; } >"$TMP/state.new"
  fi
  cat "$TMP/state.new" >"$STATE"
}

if [ "$NEWC" -gt 0 ] || [ "$CHANGED" = true ] || [ "$ALWAYS" = 1 ]; then
  printf '%s\n' "$OUT"
  if [ "$ADVANCE" = 1 ]; then
    set_cursor comment "$NEXT_C"
    set_cursor checks "$SIG"
  fi
  exit 0
fi
exit 1

#!/usr/bin/env bash
# promote-preflight.sh — the read-only preflight of a staging -> production promotion.
#
# Usage: bash .claude/scripts/promote-preflight.sh --prod <branch> --staging <branch> --workflow <name>
#                  [--ticket-prefix <PFX>] [--remote origin] [--no-fetch]
#   --workflow       the CI workflow whose run must be green (promote runbook step 1: without it
#                    the newest run on the branch may be another workflow, a nightly or a deploy)
#   --ticket-prefix  the tracker prefix to enumerate (PFX-123); default $HARNESS_TICKET_PREFIX;
#                    without one the ticket list is skipped and said so
#   --no-fetch       use the remote-tracking refs as they are (default: git fetch <remote> <prod>
#                    <staging>)
#
# Checks, from the promote runbook step 1:
#   - the latest <workflow> run on <staging> is completed, its conclusion is success, and its
#     headSha equals the staging head being promoted (a green run of an older commit proves nothing);
#   - commits to promote: rev-list --count <prod>..<staging> (blocked at 0: nothing to ship);
#   - drift: rev-list --no-merges --count <staging>..<prod> must be 0 (a feature commit that
#     originated on the release branch; prior promotion merge commits are excluded);
#   - the tickets in the promotion: git log <prod>..<staging> subjects, deduplicated.
#
# It never opens a PR, merges, comments, labels or pushes. Its only writes are the git fetch and,
# for gh, one `gh run list` read. The go-ahead to merge stays with the owner (the promotion diff
# and ticket list are shown first), and the merge is always a merge commit.
#
# JSON: {status: ready|blocked, staging:{branch, sha}, prod:{branch, sha}, ci:{state, conclusion,
# head_sha, url, matches_head}, promote_count, drift_count, tickets[], tickets_skipped, blockers[]}.
# ci.state is ok, none, running, failed, stale or unavailable. Exit: 0 ready, 1 blocked, 2 bad
# input, 3 unsupported (gh is not installed, so CI cannot be checked).
set -u

die() { echo "promote-preflight: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

PROD="" STAGING="" WORKFLOW="" PFX="${HARNESS_TICKET_PREFIX:-}" REMOTE=origin FETCH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --prod) [ $# -ge 2 ] || die "--prod needs a branch"; PROD="$2"; shift ;;
    --staging) [ $# -ge 2 ] || die "--staging needs a branch"; STAGING="$2"; shift ;;
    --workflow) [ $# -ge 2 ] || die "--workflow needs a name"; WORKFLOW="$2"; shift ;;
    --ticket-prefix) [ $# -ge 2 ] || die "--ticket-prefix needs a prefix"; PFX="$2"; shift ;;
    --remote) [ $# -ge 2 ] || die "--remote needs a name"; REMOTE="$2"; shift ;;
    --no-fetch) FETCH=0 ;;
    *) die "usage: promote-preflight.sh --prod B --staging B --workflow W [--ticket-prefix PFX] [--remote R] [--no-fetch]" ;;
  esac
  shift
done
[ -n "$PROD" ] && [ -n "$STAGING" ] || die "--prod and --staging are required"
[ -n "$WORKFLOW" ] || die "--workflow is required (the newest run on a branch may be another workflow)"
case "$PFX" in *[!A-Za-z0-9_]*) die "the ticket prefix must match [A-Za-z0-9_]+" ;; esac

if ! command -v gh >/dev/null 2>&1; then
  jq -nc '{status: "unsupported", reason: "gh is not installed, so the CI run cannot be checked", blockers: ["gh is not installed"]}'
  exit 3
fi
if [ "$FETCH" = 1 ]; then
  git fetch -q "$REMOTE" "$PROD" "$STAGING" >/dev/null 2>&1 || die "git fetch $REMOTE $PROD $STAGING failed"
fi
S_SHA="$(git rev-parse --verify -q "$REMOTE/$STAGING^{commit}")" || die "cannot resolve $REMOTE/$STAGING"
P_SHA="$(git rev-parse --verify -q "$REMOTE/$PROD^{commit}")" || die "cannot resolve $REMOTE/$PROD"

BLOCKERS='[]'
block() { BLOCKERS="$(printf '%s' "$BLOCKERS" | jq -c --arg b "$1" '. + [$b]')"; }

# CI: the newest run of the workflow on the staging branch.
CI='{"state":"unavailable","conclusion":null,"head_sha":null,"url":null,"matches_head":false}'
RUN="$(gh run list --workflow "$WORKFLOW" --branch "$STAGING" --limit 1 --json status,conclusion,headSha,url 2>/dev/null)"
if [ -z "$RUN" ] || ! printf '%s' "$RUN" | jq -e 'type == "array"' >/dev/null 2>&1; then
  block "could not read the CI runs of workflow '$WORKFLOW' on $STAGING (gh run list failed)"
elif [ "$(printf '%s' "$RUN" | jq length)" = 0 ]; then
  CI='{"state":"none","conclusion":null,"head_sha":null,"url":null,"matches_head":false}'
  block "no run of workflow '$WORKFLOW' on $STAGING"
else
  CI="$(printf '%s' "$RUN" | jq -c --arg s "$S_SHA" '.[0] | . as $r | {conclusion, head_sha: .headSha, url, matches_head: (.headSha == $s),
    state: (if .status != "completed" then "running" elif .headSha != $s then "stale" elif .conclusion == "success" then "ok" else "failed" end)}')"
  case "$(printf '%s' "$CI" | jq -r .state)" in
    ok) ;;
    running) block "the latest CI run is not finished" ;;
    stale) block "the latest CI run is for $(printf '%s' "$CI" | jq -r '.head_sha[0:12]'), not the staging head $(printf '%s' "$S_SHA" | cut -c1-12)" ;;
    *) block "the latest CI run concluded $(printf '%s' "$CI" | jq -r .conclusion)" ;;
  esac
fi

COUNT="$(git rev-list --count "$REMOTE/$PROD..$REMOTE/$STAGING")"
DRIFT="$(git rev-list --no-merges --count "$REMOTE/$STAGING..$REMOTE/$PROD")"
[ "$COUNT" -gt 0 ] || block "nothing to promote: $STAGING has no commits beyond $PROD"
[ "$DRIFT" = 0 ] || block "$DRIFT feature commit(s) originated on $PROD: back-merge to $STAGING before promoting"

TICKETS='[]' SKIPPED=false
if [ -n "$PFX" ]; then
  TICKETS="$(git log "$REMOTE/$PROD..$REMOTE/$STAGING" --pretty=%s | grep -oE "$PFX-[0-9]+" | sort -u | jq -R . | jq -sc .)"
else
  SKIPPED=true
fi

jq -nc --arg sb "$STAGING" --arg ss "$S_SHA" --arg pb "$PROD" --arg ps "$P_SHA" --argjson ci "$CI" --argjson count "$COUNT" \
  --argjson drift "$DRIFT" --argjson t "$TICKETS" --argjson skipped "$SKIPPED" --argjson b "$BLOCKERS" \
  '{status: (if ($b | length) == 0 then "ready" else "blocked" end), staging: {branch: $sb, sha: $ss}, prod: {branch: $pb, sha: $ps},
    ci: $ci, promote_count: $count, drift_count: $drift, tickets: $t, tickets_skipped: $skipped, blockers: $b}'
[ "$BLOCKERS" = '[]' ]

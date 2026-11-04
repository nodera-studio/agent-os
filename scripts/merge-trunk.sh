#!/usr/bin/env bash
# merge-trunk.sh — bring the trunk into a wave worktree at the start of a fix cycle, with the
# squash-merged-base recipe when the branch was cut from, or merged with, a sibling wave's
# pre-squash commit. Never rebases, never pushes.
#
# Usage: bash .claude/scripts/merge-trunk.sh --worktree <path> --trunk <ref>
#                  [--a-pr <N> | --a-tip <sha> --sq <sha>] [--fetch] [--allow-dirty]
#   --worktree   the wave's checkout (the merge happens there, on its current branch)
#   --trunk      the ref to merge, normally origin/<staging trunk>
#   --a-pr N     sibling wave A's PR: its last tip (headRefOid) and squash commit (mergeCommit) come
#                from `gh pr view`, and `pull/N/head` is fetched; needs gh
#   --a-tip/--sq the same two commits given directly (no gh): A's last pre-squash tip, and the
#                squash commit on the trunk
#   --fetch      `git fetch origin` first (and pull/N/head with --a-pr)
#   --allow-dirty merge although `git status --short` is not empty (default: refuse, so the
#                merge never mixes with uncommitted edits; have their agent commit or stash first)
# Without --a-pr/--a-tip it is a plain `git merge --no-edit <trunk>`.
#
# The recipe (loop-procedures.md, "Squash-merged base"): CUT = merge-base(HEAD, A's tip); the trunk's
# squash commit SQ gets CUT as a second parent through a temporary `git replace --graft`, so
# `git merge` picks the right base and leaves an ordinary index for any real conflict. The graft is
# deleted immediately after the merge, before anything else runs, and also if the script is
# interrupted or fails: nothing remains in refs/replace, which every worktree of the repo shares.
# Do not run other git commands in the repo while it runs, and never push refs/replace. Both merge
# bases are previewed first with `git merge-tree --write-tree --name-only` (needs git 2.38).
#
# JSON: {status, base, trunk, trunk_sha, head_before, head_after, cut, sq, a_tip, conflicts[],
# preview:{plain:{clean, conflicts[]}, cut:{...}}, refs_replace_remaining, reason}.
# status is merged, up-to-date, conflict (the merge stopped with conflicts in the index, to resolve
# as usual) or error. base is plain or cut. Exit: 0 merged or up to date, 1 conflict, 2 error
# (nothing merged, no graft left).
set -u

WT="" TRUNK="" A_PR="" A_TIP="" SQ="" FETCH=0 DIRTY_OK=0
GRAFTED=0 SQ_FULL=""
unset GIT_NO_REPLACE_OBJECTS # a graft only works with replace refs honoured

fail() { # fail <reason>: JSON error, exit 2
  jq -nc --arg r "$1" --arg t "$TRUNK" '{status: "error", trunk: $t, reason: $r, refs_replace_remaining: 0}'
  exit 2
}
command -v jq >/dev/null 2>&1 || { echo "merge-trunk: jq is not installed" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) [ $# -ge 2 ] || fail "--worktree needs a path"; WT="$2"; shift ;;
    --trunk) [ $# -ge 2 ] || fail "--trunk needs a ref"; TRUNK="$2"; shift ;;
    --a-pr) [ $# -ge 2 ] || fail "--a-pr needs a number"; A_PR="$2"; shift ;;
    --a-tip) [ $# -ge 2 ] || fail "--a-tip needs a sha"; A_TIP="$2"; shift ;;
    --sq) [ $# -ge 2 ] || fail "--sq needs a sha"; SQ="$2"; shift ;;
    --fetch) FETCH=1 ;;
    --allow-dirty) DIRTY_OK=1 ;;
    *) fail "usage: merge-trunk.sh --worktree <path> --trunk <ref> [--a-pr N | --a-tip SHA --sq SHA] [--fetch] [--allow-dirty]" ;;
  esac
  shift
done
[ -n "$WT" ] && [ -n "$TRUNK" ] || fail "--worktree and --trunk are required"
git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not a git work tree: $WT"
{ [ -z "$A_TIP" ] && [ -z "$SQ" ]; } || { [ -n "$A_TIP" ] && [ -n "$SQ" ]; } || fail "--a-tip and --sq go together"
{ [ -z "$A_PR" ] || [ -z "$A_TIP" ]; } || fail "use --a-pr or --a-tip/--sq, not both"
g() { git -C "$WT" "$@"; }

drop_graft() { # idempotent: remove our replace ref, if we made it
  [ "$GRAFTED" = 1 ] || return 0
  g replace -d "$SQ_FULL" >/dev/null 2>&1
  GRAFTED=0
}
trap drop_graft EXIT
trap 'drop_graft; exit 130' INT
trap 'drop_graft; exit 143' TERM

[ "$DIRTY_OK" = 1 ] || [ -z "$(g status --short)" ] || fail "the worktree has uncommitted changes (commit or stash them first)"
if [ "$FETCH" = 1 ]; then
  g fetch -q origin >/dev/null 2>&1 || fail "git fetch origin failed"
  [ -z "$A_PR" ] || g fetch -q origin "pull/$A_PR/head" >/dev/null 2>&1 || fail "git fetch pull/$A_PR/head failed"
fi
TRUNK_SHA="$(g rev-parse --verify -q "$TRUNK^{commit}")" || fail "cannot resolve the trunk ref: $TRUNK"
HEAD_BEFORE="$(g rev-parse HEAD 2>/dev/null)" || fail "the worktree has no commits"

if [ -n "$A_PR" ]; then
  command -v gh >/dev/null 2>&1 || fail "gh is not installed (use --a-tip and --sq)"
  A_TIP="$(gh pr view "$A_PR" --json headRefOid -q .headRefOid 2>/dev/null)" || fail "gh pr view $A_PR failed"
  SQ="$(gh pr view "$A_PR" --json mergeCommit -q .mergeCommit.oid 2>/dev/null)" || fail "gh pr view $A_PR failed"
  [ -n "$A_TIP" ] && [ -n "$SQ" ] && [ "$SQ" != null ] || fail "PR $A_PR has no head or merge commit yet (is it merged?)"
fi

refs_left() { g for-each-ref refs/replace | wc -l | tr -d ' '; }
conflicts_of() { awk 'NR == 1 { next } /^$/ { exit } { print }'; } # merge-tree --name-only output
list_json() { jq -R . | jq -sc .; }

if g merge-base --is-ancestor "$TRUNK_SHA" HEAD 2>/dev/null; then
  jq -nc --arg t "$TRUNK" --arg ts "$TRUNK_SHA" --arg h "$HEAD_BEFORE" \
    '{status: "up-to-date", base: "plain", trunk: $t, trunk_sha: $ts, head_before: $h, head_after: $h, conflicts: [], refs_replace_remaining: 0}'
  exit 0
fi

BASE=plain CUT="" PREVIEW='null'
if [ -n "$A_TIP" ]; then
  BASE="cut"
  A_FULL="$(g rev-parse --verify -q "$A_TIP^{commit}")" || fail "cannot resolve wave A's tip: $A_TIP"
  SQ_FULL="$(g rev-parse --verify -q "$SQ^{commit}")" || fail "cannot resolve the squash commit: $SQ"
  SQP="$(g rev-parse --verify -q "$SQ_FULL^")" || fail "the squash commit has no parent"
  CUT="$(g merge-base HEAD "$A_FULL")" || fail "HEAD and wave A's tip share no history"
  g rev-parse --verify -q "refs/replace/$SQ_FULL" >/dev/null && fail "refs/replace/$SQ_FULL already exists (another graft in flight?)"
  PO="$(g merge-tree --write-tree --name-only HEAD "$TRUNK_SHA" 2>/dev/null)"; PRC=$?
  CO="$(g merge-tree --write-tree --name-only --merge-base="$CUT" HEAD "$TRUNK_SHA" 2>/dev/null)"; CRC=$?
  [ "$PRC" -le 1 ] && [ "$CRC" -le 1 ] || fail "git merge-tree failed (git 2.38 or newer is needed)"
  PREVIEW="$(jq -nc --argjson pc "$([ "$PRC" = 0 ] && echo true || echo false)" --argjson cc "$([ "$CRC" = 0 ] && echo true || echo false)" \
    --argjson pf "$(printf '%s\n' "$PO" | conflicts_of | list_json)" --argjson cf "$(printf '%s\n' "$CO" | conflicts_of | list_json)" \
    '{plain: {clean: $pc, conflicts: $pf}, cut: {clean: $cc, conflicts: $cf}}')"
  g replace --graft "$SQ_FULL" "$SQP" "$CUT" >/dev/null 2>&1 || fail "git replace --graft failed"
  GRAFTED=1
fi

g merge --no-edit "$TRUNK_SHA" >/dev/null 2>&1 </dev/null
RC=$?
drop_graft # right away, before resolving anything

HEAD_AFTER="$(g rev-parse HEAD 2>/dev/null)"
CONF="$(g diff --name-only --diff-filter=U 2>/dev/null | list_json)"
case "$RC" in 0) STATUS=merged ;; 1) STATUS=conflict ;; *) STATUS=error ;; esac
# exit 1 without unmerged paths is a stopped merge (a failing hook), not a conflict to resolve
[ "$STATUS" = conflict ] && [ "$CONF" = '[]' ] && STATUS=error
jq -nc --arg s "$STATUS" --arg b "$BASE" --arg t "$TRUNK" --arg ts "$TRUNK_SHA" --arg hb "$HEAD_BEFORE" --arg ha "$HEAD_AFTER" \
  --arg cut "$CUT" --arg sq "$SQ_FULL" --arg a "${A_FULL:-}" --argjson conf "$CONF" --argjson prev "$PREVIEW" --argjson left "$(refs_left)" --arg rc "$RC" \
  '{status: $s, base: $b, trunk: $t, trunk_sha: $ts, head_before: $hb, head_after: $ha,
    cut: (if $cut == "" then null else $cut end), sq: (if $sq == "" then null else $sq end), a_tip: (if $a == "" then null else $a end),
    conflicts: $conf, preview: $prev, refs_replace_remaining: $left}
   + (if $s == "error" then {reason: ("git merge exited " + $rc)} else {} end)'
case "$STATUS" in merged) exit 0 ;; conflict) exit 1 ;; *) exit 2 ;; esac

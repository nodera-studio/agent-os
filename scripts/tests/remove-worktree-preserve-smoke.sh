#!/bin/bash
# remove-worktree-preserve-smoke.sh — remove-worktree.sh keeps a worktree's working material.
#
# Usage: /bin/bash .claude/scripts/tests/remove-worktree-preserve-smoke.sh
# Bash 3.2, no network, no real companion: a temp repo carries copies of remove-worktree.sh and
# codex-procs.sh and lib/proc-common.sh, and every run uses CLAUDE_PLUGIN_DATA and TMPDIR under the mktemp work dir with
# --force-no-state. Case (d) adds a local bare origin for the branch-deletion check. Prints ok/FAIL
# per case; exit 1 on any FAIL.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SCRIPTS="$TEST_DIR/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/remove-worktree-preserve-smoke.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$WORK/tmp" "$REPO/.claude/scripts/lib"
G() { git -C "$REPO" -c user.name=smoke -c user.email=smoke@example.invalid \
  -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
git init -q "$REPO"
printf '%s\n' .claude/worktrees/ .claude/evidence/ .claude/plans/ target/ >"$REPO/.gitignore"
cp "$SCRIPTS/remove-worktree.sh" "$SCRIPTS/codex-procs.sh" "$REPO/.claude/scripts/"
cp "$SCRIPTS/lib/proc-common.sh" "$REPO/.claude/scripts/lib/"
G add -A
G commit -q -m init
G worktree add -q "$REPO/.claude/worktrees/w1" -b t1 >/dev/null 2>&1
W1="$REPO/.claude/worktrees/w1"

# The main checkout has a different p.md and an identical same.md.
mkdir -p "$REPO/.claude/plans"
printf 'main plan\n' >"$REPO/.claude/plans/p.md"
printf 'same\n' >"$REPO/.claude/plans/same.md"
mkdir -p "$W1/.claude/evidence/w1" "$W1/.claude/plans" "$W1/.claude/reviews" "$W1/target"
printf 'shot\n' >"$W1/.claude/evidence/w1/shot.txt"
printf 'worktree plan\n' >"$W1/.claude/plans/p.md"
printf 'same\n' >"$W1/.claude/plans/same.md"
printf 'review\n' >"$W1/.claude/reviews/r.md"
printf 'build\n' >"$W1/target/x"
printf 'scratch\n' >"$W1/notes.txt"       # untracked outside the kept dirs: discarded and listed
printf 'changed\n' >>"$W1/.gitignore"      # a tracked change: discarded and listed

FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
run() { # run ARGS...: sets OUT and RC
  RC=0
  OUT="$(cd "$REPO" && env CLAUDE_PLUGIN_DATA="$WORK/none" TMPDIR="$WORK/tmp" \
    /bin/bash "$REPO/.claude/scripts/remove-worktree.sh" --force-no-state "$@" 2>&1)" || RC=$?
}
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

# (a) --dry-run names the three new or different files and changes nothing.
run --dry-run "$W1"
n="$(printf '%s\n' "$OUT" | grep -c '^would preserve ' || true)"
if [ "$RC" = 0 ] && [ "$n" = 3 ] && has "would preserve .claude/evidence/w1/shot.txt -> $REPO/.claude/evidence/w1/shot.txt" \
  && has "would preserve .claude/reviews/r.md -> $REPO/.claude/reviews/r.md" \
  && has "would preserve .claude/plans/p.md -> $REPO/.claude/evidence/from-worktrees/w1-" \
  && ! has same.md && ! has target/x; then ok "(a) dry run lists shot.txt, r.md and p.md only"
else fail "(a) dry run: rc $RC, $n line(s): $OUT"; fi
if [ -d "$W1" ] && [ ! -e "$REPO/.claude/evidence" ] && [ ! -e "$REPO/.claude/reviews" ] \
  && [ "$(cat "$REPO/.claude/plans/p.md")" = "main plan" ]; then ok "(a) dry run changed nothing"
else fail "(a) dry run changed something"; fi

# (b) the real run preserves, never overwrites, skips duplicates and leaves target/ behind.
run "$W1"
if [ "$RC" = 0 ] && [ ! -e "$W1" ]; then ok "(b) worktree removed"; else fail "(b) rc $RC: $OUT"; fi
if [ "$(cat "$REPO/.claude/evidence/w1/shot.txt" 2>/dev/null)" = shot ] \
  && [ "$(cat "$REPO/.claude/reviews/r.md" 2>/dev/null)" = review ]; then ok "(b) shot.txt and r.md copied to the same path"
else fail "(b) shot.txt or r.md missing: $OUT"; fi
moved=""
for m in "$REPO"/.claude/evidence/from-worktrees/w1-*/.claude/plans/p.md; do [ -f "$m" ] && moved="$m"; done
if [ -n "$moved" ] && [ "$(cat "$moved")" = "worktree plan" ] \
  && [ "$(cat "$REPO/.claude/plans/p.md")" = "main plan" ]; then ok "(b) the different p.md went to from-worktrees/, main p.md unchanged"
else fail "(b) p.md: moved '${moved:-none}': $OUT"; fi
dup=""
for m in "$REPO"/.claude/evidence/from-worktrees/w1-*/.claude/plans/same.md; do [ -e "$m" ] && dup="$m"; done
if [ -z "$dup" ] && ! has same.md; then ok "(b) identical same.md not duplicated"
else fail "(b) same.md duplicated: $OUT"; fi
if [ ! -e "$REPO/target/x" ] && ! has target/x; then ok "(b) target/x not preserved"; else fail "(b) target/x preserved"; fi
if has "warning: discarding 2 uncommitted path(s) in $W1:" && has " M .gitignore" && has "?? notes.txt" \
  && ! has "?? .claude/reviews/r.md"; then ok "(b) discard warning lists .gitignore and notes.txt, not preserved files"
else fail "(b) discard warning: $OUT"; fi
if has "preserved .claude/evidence/w1/shot.txt -> "; then ok "(b) each copy printed"; else fail "(b) no preserved line: $OUT"; fi

# (c) a failed copy exits 1 and keeps the worktree.
G worktree add -q "$REPO/.claude/worktrees/w2" -b t2 >/dev/null 2>&1
W2="$REPO/.claude/worktrees/w2"
mkdir -p "$W2/.claude/evidence/w2"
printf 'shot2\n' >"$W2/.claude/evidence/w2/shot.txt"
mv "$REPO/.claude/evidence" "$WORK/evidence-b"
printf 'not a directory\n' >"$REPO/.claude/evidence"
run "$W2"
if [ "$RC" = 1 ] && [ -d "$W2" ] && has "could not preserve .claude/evidence/w2/shot.txt; nothing removed"; then
  ok "(c) failed copy: exit 1, worktree kept"
else fail "(c) rc $RC, worktree $([ -d "$W2" ] && echo kept || echo gone): $OUT"; fi

# (d) branch deletion checks the base branches on origin (HARNESS_BASE_BRANCHES, else origin's
# default branch): a tip merged into origin/staging goes, an unmerged tip and a base branch stay.
rm -f "$REPO/.claude/evidence"
git init -q --bare "$WORK/origin.git"
G remote add origin "$WORK/origin.git"
G branch -q staging
G push -q origin "HEAD:refs/heads/main" >/dev/null 2>&1   # both base branches exist on origin
G worktree add -q "$REPO/.claude/worktrees/w3" -b t3 >/dev/null 2>&1
W3="$REPO/.claude/worktrees/w3"
G -C "$W3" commit -q --allow-empty -m "t3 work"
G push -q origin "t3:staging" >/dev/null 2>&1
G worktree add -q "$REPO/.claude/worktrees/w4" -b t4 >/dev/null 2>&1
W4="$REPO/.claude/worktrees/w4"
G -C "$W4" commit -q --allow-empty -m "t4 unmerged"
run_b() { # run_b BASES ARGS...: like run, with HARNESS_BASE_BRANCHES=BASES
  local bases="$1"
  shift
  RC=0
  OUT="$(cd "$REPO" && env CLAUDE_PLUGIN_DATA="$WORK/none" TMPDIR="$WORK/tmp" HARNESS_BASE_BRANCHES="$bases" \
    /bin/bash "$REPO/.claude/scripts/remove-worktree.sh" --force-no-state "$@" 2>&1)" || RC=$?
}
run_b "staging main" "$W3" staging
if [ "$RC" = 1 ] && has "will not delete base branch staging" && [ -d "$W3" ]; then ok "(d) a base branch is never deleted"
else fail "(d) base branch: rc $RC: $OUT"; fi
run_b "staging main" "$W4" t4
if [ "$RC" = 1 ] && has "its tip is not in origin/{staging,main}" && [ -d "$W4" ]; then ok "(d) unmerged t4 refused, worktree kept"
else fail "(d) unmerged t4: rc $RC: $OUT"; fi
run_b "staging" "$W3" t3
if [ "$RC" = 0 ] && [ ! -e "$W3" ] && has "its tip is in freshly fetched origin/staging" \
  && ! G rev-parse -q --verify refs/heads/t3 >/dev/null; then ok "(d) t3 merged into origin/staging: worktree and branch removed"
else fail "(d) merged t3: rc $RC: $OUT"; fi

# (e) codex-procs.sh is optional (AC-050): with it, no companion state store refuses the removal; without
# it there is no companion to ask, so the same run (no --force-no-state) removes the worktree.
G worktree add -q "$REPO/.claude/worktrees/w5" -b t5 >/dev/null 2>&1
W5="$REPO/.claude/worktrees/w5"
run_nf() { # run_nf ARGS...: like run, without --force-no-state
  RC=0
  OUT="$(cd "$REPO" && env CLAUDE_PLUGIN_DATA="$WORK/none" TMPDIR="$WORK/tmp" \
    /bin/bash "$REPO/.claude/scripts/remove-worktree.sh" "$@" 2>&1)" || RC=$?
}
run_nf "$W5"
if [ "$RC" = 1 ] && has "no companion state store exists" && [ -d "$W5" ]; then ok "(e) with the helper, no state store refuses"
else fail "(e) with helper: rc $RC: $OUT"; fi
rm -f "$REPO/.claude/scripts/codex-procs.sh"
run_nf "$W5" t5
if [ "$RC" = 0 ] && [ ! -e "$W5" ] && ! has "companion" && ! G rev-parse -q --verify refs/heads/t5 >/dev/null; then
  ok "(e) without the helper, the worktree and its branch are removed"
else fail "(e) without helper: rc $RC: $OUT"; fi

if [ "$FAILS" -gt 0 ]; then echo "$FAILS case(s) failed"; exit 1; fi
echo "all cases passed"

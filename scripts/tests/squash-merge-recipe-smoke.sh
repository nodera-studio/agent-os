#!/bin/bash
# squash-merge-recipe-smoke.sh — the "Squash-merged base" recipe in
# .claude/skills/auto-mode/references/loop-procedures.md (step 7), run through merge-trunk.sh, against
# a temp repo. The temp repo's `main` stands in for the integration branch the wave PRs squash-merge
# into.
#
# Usage: /bin/bash .claude/scripts/tests/squash-merge-recipe-smoke.sh
# Bash 3.2, no network (merge-trunk.sh gets the wave A tip and squash commit directly, no gh). Needs jq. The temp repos ignore the global and system git config, so no hook,
# signing key or alias of the owner's runs. History built per repo:
#   main:  seq 1 30 > f
#   waveA: line 5 -> A5 (this commit is CUT)
#   waveB: from CUT, A5 -> B5 and line 25 -> B25
#   main:  squash-merge of waveA (SQ), then line 15 -> M15 (and line 25 -> M25 in the variant)
# Cases: (a) the plain base conflicts; (b) the cut base merges clean (tree T); (c) the graft recipe
# merges to T with the ordinary parents and leaves refs/replace empty; (d) a real conflict left
# by the cut base exits 1 with only f conflicted, and refs/replace is still empty.
# Further cases for merge-trunk.sh itself: (e) no sibling wave = a plain merge; (f) a dirty worktree
# is refused; (g) a failing hook leaves an error and no graft; (h) TERM mid-merge still removes the
# graft; (i) an already merged trunk is "up-to-date"; (j) a bad squash commit is an error.
# Prints ok/FAIL per case; exit 1 on any FAIL.
set -euo pipefail

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squash-merge-smoke.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@example.invalid
export GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@example.invalid
unset GIT_NO_REPLACE_OBJECTS GIT_DIR GIT_WORK_TREE

FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
# expect <ok text> <FAIL text> <test args…>
expect() { local y="$1" n="$2"; shift 2; if [ "$@" ]; then ok "$y"; else fail "$n"; fi; }

# set_line <file> <line number> <text>
set_line() { awk -v n="$2" -v t="$3" 'NR == n { print t; next } { print }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"; }

# build <repo dir> <main edits line 25: 0|1>; sets CUT and SQ, leaves waveB checked out.
build() {
  local r="$1"
  git init -q -b main "$r"
  seq 1 30 >"$r/f"
  git -C "$r" add f && git -C "$r" commit -q -m base
  git -C "$r" switch -q -c waveA
  set_line "$r/f" 5 A5 && git -C "$r" commit -q -am A5
  CUT="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" switch -q -c waveB
  set_line "$r/f" 5 B5 && set_line "$r/f" 25 B25 && git -C "$r" commit -q -am B
  git -C "$r" switch -q main
  git -C "$r" merge -q --squash waveA >/dev/null && git -C "$r" commit -q -m "wave A (#1)"
  SQ="$(git -C "$r" rev-parse HEAD)"
  set_line "$r/f" 15 M15
  if [ "$2" = 1 ]; then set_line "$r/f" 25 M25; fi
  git -C "$r" commit -q -am M
  git -C "$r" switch -q waveB
}

replace_refs() { git -C "$1" for-each-ref refs/replace | wc -l | tr -d ' '; }

# recipe <repo dir>: merge-trunk.sh with main standing in for the fetched integration branch and
# waveA's last tip for headRefOid; sets RC and OUT (its JSON).
HERE="$(cd "$(dirname "$0")" && pwd -P)"
MERGE_TRUNK="$HERE/../merge-trunk.sh"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed"; exit 1; }
recipe() {
  RC=0; OUT="$(bash "$MERGE_TRUNK" --worktree "$1" --trunk main --a-tip waveA --sq "$SQ")" || RC=$?
}

# --- clean variant: cases (a)-(c) ---
R="$WORK/clean"
build "$R" 0
OLD_HEAD="$(git -C "$R" rev-parse HEAD)"
MAIN_TIP="$(git -C "$R" rev-parse main)"

if git -C "$R" merge-tree --write-tree HEAD main >/dev/null 2>&1; then
  fail "(a) plain merge-tree base exited 0; expected a conflict"
else
  rc=$?
  if [ "$rc" -eq 1 ]; then ok "(a) plain base conflicts (exit 1)"; else fail "(a) plain merge-tree exited $rc, expected 1"; fi
fi

T=""
if T="$(git -C "$R" merge-tree --write-tree --merge-base="$CUT" HEAD main)"; then
  ok "(b) cut base merges clean (tree $T)"
else
  fail "(b) merge-tree --merge-base=CUT exited non-zero"
fi

recipe "$R"
if [ "$RC" -ne 0 ]; then
  fail "(c) graft recipe merge exited $RC, expected 0"
else
  expect "(c) JSON says merged on the cut base" "(c) JSON: $OUT" "$(echo "$OUT" | jq -r '.status + ":" + .base')" = merged:cut
  expect "(c) the preview shows the plain base conflicting and the cut base clean" "(c) preview: $OUT" \
    "$(echo "$OUT" | jq -r '(.preview.plain.clean | tostring) + ":" + (.preview.cut.clean | tostring)')" = false:true
  tree="$(git -C "$R" rev-parse 'HEAD^{tree}')"
  parents="$(git -C "$R" rev-list --parents -n 1 HEAD | cut -d' ' -f2-)"
  want="$OLD_HEAD $MAIN_TIP"
  expect "(c) merge tree equals the cut-base tree" "(c) merge tree $tree != $T" "$tree" = "$T"
  expect "(c) parents are the old HEAD and main" "(c) parents '$parents', expected '$want'" "$parents" = "$want"
  if grep -qx B5 "$R/f" && grep -qx M15 "$R/f" && grep -qx B25 "$R/f" && ! grep -qx A5 "$R/f"; then
    ok "(c) f has B5, M15 and B25"
  else
    fail "(c) f lacks B5/M15/B25: $(tr '\n' ' ' <"$R/f")"
  fi
fi
expect "(c) refs/replace is empty" "(c) refs/replace not empty" "$(replace_refs "$R")" = 0

# --- conflict variant: case (d) ---
R="$WORK/conflict"
build "$R" 1
recipe "$R"
if [ "$RC" -eq 1 ]; then ok "(d) recipe exits 1 on a real conflict"; else fail "(d) recipe exited $RC, expected 1"; fi
conflicted="$(git -C "$R" diff --name-only --diff-filter=U)"
expect "(d) only f is conflicted" "(d) conflicted files: '$conflicted'" "$conflicted" = f
expect "(d) JSON says conflict, base cut, f" "(d) JSON: $OUT" "$(echo "$OUT" | jq -r '.status + ":" + .base + ":" + (.conflicts | join(","))')" = conflict:cut:f
if grep -q '^<<<<<<<' "$R/f" && ! grep -qx A5 "$R/f" && grep -qx B5 "$R/f"; then
  ok "(d) the conflict is line 25 only (line 5 resolved to B5)"
else
  fail "(d) unexpected conflict content: $(tr '\n' ' ' <"$R/f")"
fi
expect "(d) refs/replace is empty" "(d) refs/replace not empty" "$(replace_refs "$R")" = 0

# --- (e) no sibling wave: a plain merge ---
R="$WORK/plain"
build "$R" 0
RC=0; OUT="$(bash "$MERGE_TRUNK" --worktree "$R" --trunk main)" || RC=$?
expect "(e) a plain merge conflicts like the plain base (exit 1)" "(e) exit $RC, $OUT" "$RC:$(echo "$OUT" | jq -r '.status + ":" + .base')" = 1:conflict:plain
git -C "$R" merge --abort
expect "(e) refs/replace is empty" "(e) refs/replace not empty" "$(replace_refs "$R")" = 0

# --- (f) a dirty worktree is refused ---
R="$WORK/dirty"
build "$R" 0
head0="$(git -C "$R" rev-parse HEAD)"
echo extra >>"$R/f"
recipe "$R"
expect "(f) exit 2 on uncommitted changes" "(f) exit $RC, $OUT" "$RC:$(echo "$OUT" | jq -r .status)" = 2:error
expect "(f) HEAD unchanged and no graft" "(f) moved or grafted" "$(git -C "$R" rev-parse HEAD):$(replace_refs "$R")" = "$head0:0"

# --- (g) a failing hook stops the merge: an error, and the graft is gone ---
R="$WORK/hook"
build "$R" 0
mkdir -p "$R/.git/hooks"
printf '#!/bin/sh\nexit 1\n' >"$R/.git/hooks/pre-merge-commit" && chmod +x "$R/.git/hooks/pre-merge-commit"
recipe "$R"
expect "(g) a stopped merge is an error (exit 2), not a conflict" "(g) exit $RC, $OUT" "$RC:$(echo "$OUT" | jq -r .status)" = 2:error
expect "(g) refs/replace is empty" "(g) refs/replace not empty" "$(replace_refs "$R")" = 0

# --- (h) TERM during the merge still removes the graft ---
R="$WORK/term"
build "$R" 0
printf '#!/bin/sh\nsleep 2\n' >"$R/.git/hooks/pre-merge-commit" && chmod +x "$R/.git/hooks/pre-merge-commit"
bash "$MERGE_TRUNK" --worktree "$R" --trunk main --a-tip waveA --sq "$SQ" >/dev/null 2>&1 &
mt=$!
n=0; while [ "$(replace_refs "$R")" = 0 ] && [ "$n" -lt 40 ]; do sleep 0.1; n=$((n + 1)); done
saw="$(replace_refs "$R")"
kill -TERM "$mt" 2>/dev/null; wait "$mt" 2>/dev/null || true
expect "(h) the graft existed during the merge" "(h) no graft seen" "$saw" = 1
expect "(h) refs/replace is empty after TERM" "(h) refs/replace not empty" "$(replace_refs "$R")" = 0
git -C "$R" merge --abort 2>/dev/null || true

# --- (i) a merged trunk is up to date ---
R="$WORK/clean2"
build "$R" 0
recipe "$R"
recipe "$R"
expect "(i) merging again is up-to-date (exit 0)" "(i) exit $RC, $OUT" "$RC:$(echo "$OUT" | jq -r .status)" = 0:up-to-date

# --- (j) a bad squash commit is an error before any graft ---
R="$WORK/badsq"
build "$R" 0
RC=0; OUT="$(bash "$MERGE_TRUNK" --worktree "$R" --trunk main --a-tip waveA --sq deadbeef)" || RC=$?
expect "(j) exit 2" "(j) exit $RC, $OUT" "$RC" = 2
expect "(j) refs/replace is empty" "(j) refs/replace not empty" "$(replace_refs "$R")" = 0

if [ "$FAILS" -gt 0 ]; then echo "$FAILS case(s) failed"; exit 1; fi

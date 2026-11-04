#!/bin/bash
# clean-scratch-smoke.sh — clean-scratch.sh refusals, skips and removals, and the steer-bash rm advice.
#
# Usage: /bin/bash .claude/scripts/tests/clean-scratch-smoke.sh
# Bash 3.2, no network. TMPDIR is a temp dir under a mktemp work dir, the worktree check reads a
# temp repo (HARNESS_CLEAN_REPO), the scratch prefix is HARNESS_SCRATCH_PREFIX=proj- (case (h)
# checks the derived default), and every holder process is a background sleep loop this test
# starts and kills. The real TMPDIR is never cleaned. Prints ok/FAIL per case; exit 1 on any FAIL.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SCRIPT="$TEST_DIR/../clean-scratch.sh"
HOOK="$(cd "$TEST_DIR/../.." && pwd -P)/hooks/steer-bash.sh"
command -v jq >/dev/null 2>&1 || { echo "FAIL jq is required" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/clean-scratch-smoke.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
HOLDERS=""
cleanup() {
  local p
  for p in $HOLDERS; do kill "$p" 2>/dev/null || true; done
  for p in $HOLDERS; do wait "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

T="$WORK/tmp"        # the TMPDIR the script cleans
OUTSIDE="$WORK/outside"
REPO="$WORK/repo"    # HARNESS_CLEAN_REPO, with proj-wt registered as a worktree
export HARNESS_SCRATCH_PREFIX=proj-
mkdir -p "$T" "$OUTSIDE/keep"
G() { git -C "$REPO" -c user.name=smoke -c user.email=smoke@example.invalid \
  -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
git init -q "$REPO"
G commit -q --allow-empty -m init
G worktree add -q "$T/proj-wt" -b wt >/dev/null 2>&1

for d in proj-a proj-links-x proj-fresh proj-busy proj-cmd; do
  mkdir -p "$T/$d/sub"
  printf 'x\n' >"$T/$d/sub/f"
done
mkdir -p "$T/other-dir"
ln -s "$OUTSIDE" "$T/proj-link"
for d in proj-a proj-links-x proj-busy proj-cmd; do
  find "$T/$d" -exec touch -t 202610300000 {} +
done
touch "$T/proj-fresh/sub/f"

# Holders: a cwd inside proj-busy, a command line naming proj-cmd.
printf 'while :; do sleep 1; done\n' >"$WORK/holder.sh"
(cd "$T/proj-busy" && exec sleep 60) &
HOLDERS="$HOLDERS $!"
/bin/bash "$WORK/holder.sh" "$T/proj-cmd" &
HOLDERS="$HOLDERS $!"
# Wait (up to 20 s, for a loaded machine) until both holders are visible to ps and lsof.
ready=0 tries=0
while [ "$tries" -lt 40 ]; do
  tries=$((tries + 1))
  # Snapshots plus here-strings: `big | grep -q` under pipefail fails once ps outgrows a pipe.
  cmds="$(ps -axww -o command=)"
  cw="$(lsof -a -d cwd -Fn 2>/dev/null || true)"
  if grep -qF "$T/proj-cmd" <<<"$cmds" && grep -qxF "n$T/proj-busy" <<<"$cw"; then ready=1; break; fi
  sleep 0.5
done
[ "$ready" = 1 ] || { echo "FAIL setup: holder processes did not start" >&2; exit 1; }

FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
run() { # run ARGS...: sets OUT and RC
  RC=0
  OUT="$(env TMPDIR="$T" HARNESS_CLEAN_REPO="$REPO" /bin/bash "$SCRIPT" "$@" 2>&1)" || RC=$?
}
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

# (a) bad patterns exit 2 before anything is touched.
for bad in foo 'proj-../x'; do
  run --min-age 0 proj-a "$bad"
  if [ "$RC" = 2 ] && [ -d "$T/proj-a" ]; then ok "(a) '$bad' exits 2, proj-a untouched"
  else fail "(a) '$bad': rc $RC, proj-a $([ -d "$T/proj-a" ] && echo kept || echo gone): $OUT"; fi
done

# (b) --dry-run removes nothing and lists what would go.
run --dry-run 'proj-*'
if has "would remove $T/proj-a " && has "would remove $T/proj-links-x " \
  && [ -d "$T/proj-a" ] && [ -d "$T/proj-links-x" ]; then ok "(b) dry run lists proj-a and proj-links-x, removes nothing"
else fail "(b) dry run: rc $RC: $OUT"; fi

# (c) the real run removes the old idle entries and refuses or skips the rest.
run 'proj-*'
if [ "$RC" = 1 ]; then ok "(c) exit 1 (something refused)"; else fail "(c) exit $RC, want 1: $OUT"; fi
for d in proj-a proj-links-x; do
  if [ ! -e "$T/$d" ] && has "removed $T/$d "; then ok "(c) removed $d"; else fail "(c) $d not removed: $OUT"; fi
done
for d in proj-link proj-busy proj-cmd proj-wt; do
  if [ -e "$T/$d" ] && has "refuse: $T/$d: "; then ok "(c) refused $d ($(printf '%s\n' "$OUT" | sed -n "s#^refuse: $T/$d: ##p"))"
  else fail "(c) $d not refused: $OUT"; fi
done
if [ -e "$T/proj-fresh" ] && has "skip: $T/proj-fresh: "; then ok "(c) skipped proj-fresh"; else fail "(c) proj-fresh not skipped: $OUT"; fi
if [ -d "$T/other-dir" ] && [ -d "$OUTSIDE/keep" ]; then ok "(c) other-dir and the symlink's target remain"
else fail "(c) other-dir or $OUTSIDE/keep is gone"; fi

# (d) with the holders gone and --min-age 0, the rest goes.
for p in $HOLDERS; do kill "$p" 2>/dev/null || true; done
for p in $HOLDERS; do wait "$p" 2>/dev/null || true; done
HOLDERS=""
rest="proj-busy proj-cmd proj-fresh"
# shellcheck disable=SC2086 # rest is a list of fixed names
run --min-age 0 $rest
gone=1
for d in $rest; do [ ! -e "$T/$d" ] || gone=0; done
if [ "$RC" = 0 ] && [ "$gone" = 1 ]; then ok "(d) holders stopped: $rest removed, exit 0"
else fail "(d) rc $RC: $OUT"; fi

# (f) no usable cwd snapshot (lsof fails, or lists nothing): every entry is refused and kept.
mkdir -p "$T/proj-nolsof/sub" "$WORK/lsof-fail" "$WORK/lsof-empty"
find "$T/proj-nolsof" -exec touch -t 202610300000 {} +
printf '#!/bin/sh\nexit 1\n' >"$WORK/lsof-fail/lsof"
printf '#!/bin/sh\nexit 0\n' >"$WORK/lsof-empty/lsof"
chmod +x "$WORK/lsof-fail/lsof" "$WORK/lsof-empty/lsof"
for f in fail empty; do
  RC=0
  OUT="$(env PATH="$WORK/lsof-$f:$PATH" TMPDIR="$T" HARNESS_CLEAN_REPO="$REPO" /bin/bash "$SCRIPT" --min-age 0 proj-nolsof 2>&1)" || RC=$?
  if [ "$RC" = 1 ] && [ -d "$T/proj-nolsof" ] && has "refuse: $T/proj-nolsof: cannot check process cwds"; then
    ok "(f) lsof $f: proj-nolsof refused and kept"
  else fail "(f) lsof $f: rc $RC: $OUT"; fi
done

# (g) a TMPDIR outside the system temp roots exits 2 before anything is touched.
RC=0
OUT="$(env TMPDIR=/usr/bin HARNESS_CLEAN_REPO="$REPO" /bin/bash "$SCRIPT" --dry-run 'proj-*' 2>&1)" || RC=$?
if [ "$RC" = 2 ] && has "not under a system temp root"; then ok "(g) TMPDIR=/usr/bin exits 2"
else fail "(g) TMPDIR=/usr/bin: rc $RC: $OUT"; fi

# (h) without HARNESS_SCRATCH_PREFIX the prefix is the main checkout's name plus `-`.
MAINNAME="$(basename "$(cd "$(git -C "$TEST_DIR" rev-parse --path-format=absolute --git-common-dir)/.." && pwd -P)")"
RC=0
OUT="$(env -u HARNESS_SCRATCH_PREFIX TMPDIR="$T" HARNESS_CLEAN_REPO="$REPO" /bin/bash "$SCRIPT" --dry-run 'proj-*' 2>&1)" || RC=$?
if [ "$RC" = 2 ] && has "a ${MAINNAME}-* basename glob"; then ok "(h) default prefix is '${MAINNAME}-': proj-* refused"
else fail "(h) default prefix: rc $RC: $OUT"; fi
RC=0
OUT="$(env -u HARNESS_SCRATCH_PREFIX TMPDIR="$T" HARNESS_CLEAN_REPO="$REPO" /bin/bash "$SCRIPT" --dry-run "${MAINNAME}-*" 2>&1)" || RC=$?
if [ "$RC" = 0 ] && has "no match: ${MAINNAME}-*"; then ok "(h) '${MAINNAME}-*' accepted"
else fail "(h) '${MAINNAME}-*': rc $RC: $OUT"; fi

# (e) the hook points rm -rf of proj- scratch at the helper and leaves other rm alone.
hook() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | /bin/bash "$HOOK"; }
# hook_in DIR CMD: the hook with no prefix override and the session cwd DIR (prefix derived from it).
hook_in() { jq -n --arg c "$2" --arg d "$1" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
  | env -u HARNESS_SCRATCH_PREFIX /bin/bash "$HOOK"; }
# shellcheck disable=SC2016 # literal hook input
H="$(hook 'rm -rf "$TMPDIR/proj-flake-target"')"
if printf '%s' "$H" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && printf '%s' "$H" | grep -qF clean-scratch.sh; then ok "(e) rm -rf \$TMPDIR/proj-flake-target -> deny naming clean-scratch.sh"
else fail "(e) hook output for rm -rf \$TMPDIR/proj-flake-target: '$H'"; fi
H="$(hook 'rm -rf target/x')"
if [ -z "$H" ]; then ok "(e) rm -rf target/x -> no output"; else fail "(e) rm -rf target/x -> '$H'"; fi
# shellcheck disable=SC2016 # literal hook input
H="$(hook_in "$REPO" 'rm -rf "$TMPDIR/repo-build"')"
if printf '%s' "$H" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && printf '%s' "$H" | grep -qF "clean-scratch.sh [--dry-run] 'repo-"; then ok "(e) derived prefix: rm -rf \$TMPDIR/repo-build in repo -> deny"
else fail "(e) derived prefix: hook output '$H'"; fi
# shellcheck disable=SC2016 # literal hook input
H="$(hook_in "$REPO" 'rm -rf "$TMPDIR/other-build"')"
if [ -z "$H" ]; then ok "(e) derived prefix: rm -rf \$TMPDIR/other-build -> no output"; else fail "(e) other-build -> '$H'"; fi

# (i) the Codex helper is optional (AC-050): a copy of the script with only lib/proc-common.sh beside it
# (no codex-procs.sh) still dry-runs and removes.
NC="$WORK/nocodex"
mkdir -p "$NC/.claude/scripts/lib" "$T/proj-nc/sub"
git init -q "$NC"
cp "$TEST_DIR/../clean-scratch.sh" "$NC/.claude/scripts/"
cp "$TEST_DIR/../lib/proc-common.sh" "$NC/.claude/scripts/lib/"
[ ! -e "$NC/.claude/scripts/codex-procs.sh" ] || { echo "FAIL setup: codex-procs.sh present" >&2; exit 1; }
find "$T/proj-nc" -exec touch -t 202610300000 {} +
RC=0
OUT="$(env TMPDIR="$T" HARNESS_CLEAN_REPO="$REPO" /bin/bash "$NC/.claude/scripts/clean-scratch.sh" --dry-run --min-age 0 proj-nc 2>&1)" || RC=$?
if [ "$RC" = 0 ] && has "would remove $T/proj-nc " && [ -d "$T/proj-nc" ]; then ok "(i) no codex-procs.sh: dry run lists proj-nc"
else fail "(i) dry run: rc $RC: $OUT"; fi
RC=0
OUT="$(env TMPDIR="$T" HARNESS_CLEAN_REPO="$REPO" /bin/bash "$NC/.claude/scripts/clean-scratch.sh" --min-age 0 proj-nc 2>&1)" || RC=$?
if [ "$RC" = 0 ] && [ ! -e "$T/proj-nc" ]; then ok "(i) no codex-procs.sh: proj-nc removed"
else fail "(i) removal: rc $RC: $OUT"; fi

if [ "$FAILS" -gt 0 ]; then echo "$FAILS case(s) failed"; exit 1; fi
echo "all cases passed"

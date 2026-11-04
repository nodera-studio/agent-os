#!/usr/bin/env bash
# run-ci.sh — run the project's local CI pipeline and print one JSON result; no model is involved.
#
# Usage: bash .claude/scripts/run-ci.sh [all|checks|build|tests] [--dir <path>] [--keep-going]
#                                       [--expect-head <sha>] [--dry-run]
#   all (default) = checks + build + tests; `check` and `test` are accepted spellings.
#
# Stack detection, first match wins:
#   1. a Makefile with `ci` targets: all = `make ci` (else the ci-check, ci-build, ci-test targets
#      that exist), checks = `make ci-check`, build = `make ci-build`, tests = `make ci-test`;
#   2. a package.json with scripts: checks = format:check (or format), lint, typecheck (or
#      type-check); build = build; tests = test. The package manager comes from the lockfile
#      (pnpm-lock.yaml, yarn.lock, else npm).
# Anything else (Cargo.toml, go.mod, pyproject.toml, nothing) is reported `unsupported`; the
# script never guesses a command.
#
# Steps run in order and stop at the first failure unless --keep-going. A step that includes the
# test suite (tests, or all) runs under suite-lock.sh, so two runs never share one checkout's
# build output. Each step's output goes to a log under the scratch dir; the JSON carries only the
# last 40 lines of a failed step, so the model is called to diagnose a failure and for nothing else.
#
# Source head: the checkout's HEAD is read before the first step and again after the last. With
# --expect-head <sha> (a full or abbreviated sha), a different HEAD at the start stops the run
# before any step. A HEAD that moved during the run turns a pass into `stale-head`: a result is
# only ever about one commit.
#
# JSON: {mode, stack, dir, head, head_after, dirty, status, failed_step, logs_dir, steps:[{name,
# command, status (pass|fail|skipped), exit, seconds, locked, log, tail}]}. status is pass, fail,
# stale-head or unsupported.
# Exit: 0 pass, 1 a step failed, 2 bad input, 3 unsupported stack, 4 head mismatch or moved.
# --dry-run prints the resolved steps without running them (status `planned`, exit 0).
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
die() { echo "run-ci: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

MODE=all DIR=. KEEP=0 EXPECT="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    all | checks | build | tests) MODE="$1" ;;
    check) MODE=checks ;;
    test) MODE=tests ;;
    --dir) [ $# -ge 2 ] || die "--dir needs a path"; DIR="$2"; shift ;;
    --expect-head) [ $# -ge 2 ] || die "--expect-head needs a sha"; EXPECT="$2"; shift ;;
    --keep-going) KEEP=1 ;;
    --dry-run) DRY=1 ;;
    *) die "usage: run-ci.sh [all|checks|build|tests] [--dir <path>] [--keep-going] [--expect-head <sha>] [--dry-run]" ;;
  esac
  shift
done
cd "$DIR" 2>/dev/null || die "no such directory: $DIR"
DIR="$(pwd -P)"

HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
DIRTY=false
[ -z "$HEAD_SHA" ] || [ -z "$(git status --porcelain 2>/dev/null)" ] || DIRTY=true

STEPS="" # one "name|locked|command" per line
add() { STEPS="$STEPS$1|$2|$3
"; }
has_target() { grep -Eq "^$1[[:space:]]*:" "$MAKEFILE" 2>/dev/null; }
has_script() { jq -e --arg s "$1" '.scripts[$s] // empty' package.json >/dev/null 2>&1; }

MAKEFILE=""
for f in Makefile GNUmakefile makefile; do [ -f "$f" ] && { MAKEFILE="$f"; break; }; done
STACK=""
if [ -n "$MAKEFILE" ]; then
  case "$MODE" in
    all)
      if has_target ci; then add ci true "make ci"
      else
        has_target ci-check && add ci-check false "make ci-check"
        has_target ci-build && add ci-build false "make ci-build"
        has_target ci-test && add ci-test true "make ci-test"
      fi ;;
    checks) has_target ci-check && add ci-check false "make ci-check" ;;
    build) has_target ci-build && add ci-build false "make ci-build" ;;
    tests) has_target ci-test && add ci-test true "make ci-test" ;;
  esac
  [ -z "$STEPS" ] || STACK="make"
fi
if [ -z "$STEPS" ] && [ -f package.json ] && jq -e . package.json >/dev/null 2>&1; then
  PM=npm
  [ -f pnpm-lock.yaml ] && PM=pnpm
  [ -f yarn.lock ] && PM=yarn
  want() { # want <step name> <locked> <script>...: the first script that exists
    local n="$1" l="$2" s
    shift 2
    for s in "$@"; do has_script "$s" && { add "$n" "$l" "$PM run $s"; return 0; }; done
  }
  case "$MODE" in all | checks) want format false format:check format; want lint false lint; want typecheck false typecheck type-check ;; esac
  case "$MODE" in all | build) want build false build ;; esac
  case "$MODE" in all | tests) want test true test ;; esac
  [ -z "$STEPS" ] || STACK="$PM"
fi

emit_unsupported() {
  local found=""
  for f in Cargo.toml go.mod pyproject.toml requirements.txt pom.xml build.gradle Gemfile; do [ -f "$f" ] && found="$found $f"; done
  jq -n --arg mode "$MODE" --arg dir "$DIR" --arg head "$HEAD_SHA" --arg found "${found# }" \
    '{mode: $mode, stack: null, dir: $dir, head: $head, status: "unsupported", steps: [],
      reason: "no Makefile ci targets and no package.json scripts for this mode",
      detected_manifests: ($found | split(" ") | map(select(. != "")))}'
  exit 3
}
[ -n "$STEPS" ] || emit_unsupported

if [ -n "$EXPECT" ] && [ "${HEAD_SHA#"$EXPECT"}" = "$HEAD_SHA" ]; then
  jq -n --arg mode "$MODE" --arg stack "$STACK" --arg dir "$DIR" --arg head "$HEAD_SHA" --arg want "$EXPECT" \
    '{mode: $mode, stack: $stack, dir: $dir, head: $head, status: "stale-head", steps: [],
      reason: ("HEAD is not " + $want)}'
  exit 4
fi

PREFIX="${HARNESS_SCRATCH_PREFIX:-}"
if [ -z "$PREFIX" ]; then
  COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$COMMON" ] && PREFIX="$(basename "$(cd "$COMMON/.." && pwd -P)")-" || PREFIX="run-ci-"
fi
RES="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$RES"' EXIT
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/${PREFIX}ci-XXXXXX")" || die "cannot create the log dir"
: >"$RES/steps.ndjson"

STATUS=pass FAILED="" N=0
OLDIFS="$IFS"
IFS='
'
for line in $STEPS; do
  IFS="$OLDIFS"
  name="${line%%|*}" rest="${line#*|}"
  locked="${rest%%|*}" cmd="${rest#*|}"
  N=$((N + 1))
  log="$LOGS/$N-$name.log" rc=0 secs=0 st=skipped tail=""
  if [ "$DRY" = 1 ]; then
    st=planned
  elif [ "$STATUS" = fail ] && [ "$KEEP" = 0 ]; then
    st=skipped
  else
    t0="$(date +%s)"
    if [ "$locked" = true ]; then
      bash "$HERE/suite-lock.sh" bash -c "$cmd" >"$log" 2>&1 </dev/null || rc=$?
    else
      bash -c "$cmd" >"$log" 2>&1 </dev/null || rc=$?
    fi
    secs=$(($(date +%s) - t0))
    if [ "$rc" = 0 ]; then st=pass; else st=fail; STATUS=fail; [ -n "$FAILED" ] || FAILED="$name"; tail="$(tail -n 40 "$log")"; fi
  fi
  jq -nc --arg n "$name" --arg c "$cmd" --arg s "$st" --argjson e "$rc" --argjson t "$secs" \
    --argjson l "$locked" --arg log "$log" --arg tail "$tail" \
    '{name: $n, command: $c, status: $s, exit: $e, seconds: $t, locked: $l, log: $log, tail: $tail}' >>"$RES/steps.ndjson"
  IFS='
'
done
IFS="$OLDIFS"

HEAD_AFTER="$(git rev-parse HEAD 2>/dev/null || true)"
[ "$DRY" = 1 ] && STATUS=planned
[ "$STATUS" = pass ] && [ "$HEAD_AFTER" != "$HEAD_SHA" ] && STATUS=stale-head
jq -s --arg mode "$MODE" --arg stack "$STACK" --arg dir "$DIR" --arg head "$HEAD_SHA" --arg after "$HEAD_AFTER" \
  --argjson dirty "$DIRTY" --arg status "$STATUS" --arg failed "$FAILED" --arg logs "$LOGS" \
  '{mode: $mode, stack: $stack, dir: $dir, head: $head, head_after: $after, dirty: $dirty, status: $status,
    failed_step: (if $failed == "" then null else $failed end), logs_dir: $logs, steps: .}' "$RES/steps.ndjson"
case "$STATUS" in pass | planned) exit 0 ;; fail) exit 1 ;; *) exit 4 ;; esac

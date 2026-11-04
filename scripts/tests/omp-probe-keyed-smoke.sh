#!/usr/bin/env bash
# omp-probe-keyed.sh smoke: stub omp only, no network, no key. Cases: all green, a missing primary id,
# an unmatched launch route, tool failure on argon, no stored login, --dry-run, and no key in the output.
# Usage: /bin/bash .claude/scripts/tests/omp-probe-keyed-smoke.sh (the envcheck case needs the .claude/ project layout).
set -euo pipefail
umask 077

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROBE="$TEST_DIR/../omp-probe-keyed.sh"
command -v jq >/dev/null 2>&1 || { echo "FAIL jq is required" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/omp-probe-smoke.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home"
ln -s "$TEST_DIR/support/omp-probe" "$WORK/bin/omp"
CASES=0 FAILURES=0
SECRET='sk-smoke-0123456789'

ok() { CASES=$((CASES + 1)); printf 'PASS %s\n' "$1"; }
bad() { CASES=$((CASES + 1)); FAILURES=$((FAILURES + 1)); printf 'FAIL %s\n' "$1" >&2; }
expect() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# scenario <name> [mech] [models-json-filter]: a fresh state dir with a full catalog.
scenario() {
  local d="$WORK/$1"
  mkdir -p "$d"
  jq -cn '{models:[("gemini-4-argon","qwen3.8-max","glm-5.3","kimi-k3.1-pro","deepseek-v4.1-flash","glm-5.3-flash")
    | {provider:"opencode-go",id:.}]}' > "$d/models.json"
  printf '{"accounts":[{"provider":"opencode-go","status":"ok"}]}\n' > "$d/usage.json"
  printf '%s\n' "${2:-overlay}" > "$d/mech"
  printf '%s\n' "$d"
}
run_probe() {
  local d="$1"
  shift
  env PATH="$WORK/bin:$PATH" HOME="$WORK/home" FAKE_STATE="$d" OPENCODE_API_KEY="$SECRET" \
    /bin/bash "$PROBE" --out "$d/result.json" --evidence "$d/probe.md" "$@" > "$d/stdout" 2> "$d/stderr"
}
field() { jq -r "$2" "$1/result.json"; }

d="$(scenario all)"
printf 'HTTP 429 GoUsageLimitError: limit reached\n' > "$d/sample.txt"
run_probe "$d" --cap-sample "$d/sample.txt"
expect 'all six ids listed' jq -e '[.ids[]] | length == 6 and all' "$d/result.json"
expect 'overlay mechanism wins first' test "$(field "$d" .launch_mechanism)" = overlay
expect 'tools ok on every slot model' jq -e '.tools_ok | .argon and .qwen and .glm and .flash' "$d/result.json"
expect '--no-tools honoured' test "$(field "$d" .no_tools_flag)" = true
expect 'key survives the scrub' test "$(field "$d" .env_passthrough)" = true
expect 'authentic cap sample recognised' test "$(field "$d" .cap_signal)" = immediate
expect 'evidence file written' grep -Fq 'omp:opencode probe' "$d/probe.md"
expect 'the key is nowhere in the output' sh -c "! grep -rFq -- '$SECRET' '$d'"

# Outside an installed .claude/ project the launcher cannot be found: env passthrough is unmeasured, not false.
mkdir -p "$WORK/stubroot/scripts"
cp "$PROBE" "$WORK/stubroot/scripts/omp-probe-keyed.sh"
printf '#!/bin/sh\necho "omp-engine: sandbox launcher unavailable on main and in worktree"\nexit 4\n' > "$WORK/stubroot/scripts/omp-engine.sh"
d="$(scenario nolayout)"
env PATH="$WORK/bin:$PATH" HOME="$WORK/home" FAKE_STATE="$d" OPENCODE_API_KEY="$SECRET" \
  /bin/bash "$WORK/stubroot/scripts/omp-probe-keyed.sh" --out "$d/result.json" --evidence "$d/probe.md" > "$d/stdout" 2> "$d/stderr"
expect 'unavailable launcher leaves env passthrough null' jq -e '.env_passthrough == null' "$d/result.json"
expect 'null passthrough is explained in the evidence' grep -Fq 'env passthrough not measured' "$d/probe.md"

d="$(scenario startup startup_arg)"
run_probe "$d"
expect 'falls through to --model' test "$(field "$d" .launch_mechanism)" = startup_arg
expect 'no sample leaves cap_signal unknown' test "$(field "$d" .cap_signal)" = unknown

d="$(scenario none none)"
run_probe "$d"
expect 'no working route is none' test "$(field "$d" .launch_mechanism)" = none

d="$(scenario missing)"
jq -c '.models |= map(select(.id != "gemini-4-argon"))' "$d/models.json" > "$d/m" && mv "$d/m" "$d/models.json"
run_probe "$d"
expect 'missing primary id is false, fallback true' jq -e '.ids["gemini-4-argon"] == false and .ids["qwen3.8-max"] == true' "$d/result.json"
expect 'tool trial skips an unlisted id' jq -e '.tools_ok.argon == false' "$d/result.json"

d="$(scenario badtools)"
printf 'gemini-4-argon\n' > "$d/bad-tools"
run_probe "$d"
expect 'argon tool failure recorded alone' jq -e '.tools_ok.argon == false and .tools_ok.qwen == true' "$d/result.json"

d="$(scenario nologin)"
touch "$d/needs-key"
run_probe "$d"
expect 'stored login absent' test "$(field "$d" .login_store_ok)" = false

d="$(scenario dry)"
if env PATH="$WORK/bin:$PATH" HOME="$WORK/home" FAKE_STATE="$d" /bin/bash "$PROBE" --dry-run --out "$d/result.json" > "$d/stdout" 2>&1 \
  && [ ! -e "$d/result.json" ] && grep -Fq 'would write' "$d/stdout"; then ok '--dry-run writes nothing'; else bad '--dry-run writes nothing'; fi

printf '%s cases, %s failed\n' "$CASES" "$FAILURES"
[ "$FAILURES" -eq 0 ]

#!/bin/bash
# omp-caps-smoke.sh — smoke test for .claude/scripts/omp-caps.sh (Bash 3.2, no network; needs jq and node).
#
# Usage: /bin/bash .claude/scripts/tests/omp-caps-smoke.sh
# Cases: mark and status; bad input leaves the state alone; expired entries are ignored and dropped; clear;
# routing.sh engines sees a mark; budget counters (max_calls, max_usd, window reset, null = unlimited);
# concurrent marks all survive; a stale lock is taken over; a broken state file stops it. Exit 1 on any FAIL.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
CAPS="$HERE/../omp-caps.sh"
ROUTING="$HERE/../routing.sh"
SHIPPED="$HERE/../../routing.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/omp-caps-smoke.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
for t in jq node; do command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t not installed"; exit 1; }; done
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
expect() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else fail "$1"; fi; }
expect_not() { if "${@:2}" >/dev/null 2>&1; then fail "$1"; else ok "$1"; fi; }

# fresh <case>: a routing dir with the shipped routing.json and no state; prints its path.
fresh() {
  local d="$TMP/$1"
  mkdir -p "$d/auto-mode"
  cp "$SHIPPED" "$d/routing.json"
  printf '%s\n' "$d"
}
caps() { local d="$1"; shift; HARNESS_ROUTING_DIR="$d" /bin/bash "$CAPS" "$@"; }
ARGON=(omp:opencode argon gemini-4-argon)
GLM=(omp:opencode glm glm-5.3)

d="$(fresh mark)"
expect 'mark +1h' caps "$d" mark "${ARGON[@]}" +1h 429
expect 'status with a key: capped' caps "$d" status "${ARGON[@]}"
expect 'status lists the entry' sh -c "HARNESS_ROUTING_DIR='$d' /bin/bash '$CAPS' status | grep -Fq 'omp:opencode/argon/gemini-4-argon'"
expect 'the state file is a flat JSON object keyed engine/slot/model' jq -e '.["omp:opencode/argon/gemini-4-argon"] | .signal == "429" and (.until | test("Z$"))' "$d/state/omp-caps.json"
expect_not 'another slot is not capped' caps "$d" status "${GLM[@]}"
expect 'mark with an absolute time' caps "$d" mark "${GLM[@]}" 2999-01-01T00:00:00Z usage
expect 'both entries are kept' jq -e 'length == 2' "$d/state/omp-caps.json"

before="$(cat "$d/state/omp-caps.json")"
expect_not 'bad time is refused' caps "$d" mark "${ARGON[@]}" tomorrow 429
expect_not 'bad signal is refused' caps "$d" mark "${ARGON[@]}" +1h 500
expect_not 'bad engine id is refused' caps "$d" mark 'omp:bad id' argon x +1h 429
expect_not 'bad model id is refused' caps "$d" mark omp:opencode argon 'a b' +1h 429
if [ "$(cat "$d/state/omp-caps.json")" = "$before" ]; then ok 'refused input leaves the state alone'; else fail 'refused input changed the state'; fi

# Routing sees the mark: a capped high-stakes slot reroutes to omp:codex.
out="$(HARNESS_ROUTING_DIR="$d" /bin/bash "$ROUTING" engines security 2>/dev/null)"
case "$out" in *"omp:codex"*"omp:opencode/argon"*) ok 'routing.sh engines reroutes the capped slot' ;; *) fail "routing.sh engines ignored the mark: $out" ;; esac

# Expiry: ignored at read time, dropped by expire.
d="$(fresh expire)"
mkdir -p "$d/state"
printf '%s\n' '{"omp:opencode/argon/gemini-4-argon":{"until":"2000-01-01T00:00:00Z","signal":"429"}}' > "$d/state/omp-caps.json"
expect_not 'an expired entry is not capped' caps "$d" status "${ARGON[@]}"
expect 'status lists nothing' test -z "$(caps "$d" status)"
expect 'expire drops it from the file' sh -c "HARNESS_ROUTING_DIR='$d' /bin/bash '$CAPS' expire && jq -e 'length == 0' '$d/state/omp-caps.json'"
caps "$d" mark "${ARGON[@]}" +1h 402 >/dev/null
expect 'clear' sh -c "HARNESS_ROUTING_DIR='$d' /bin/bash '$CAPS' clear ${ARGON[*]} && ! HARNESS_ROUTING_DIR='$d' /bin/bash '$CAPS' status ${ARGON[*]}"

# Budgets: max_calls, max_usd, window reset, and null = unlimited.
d="$(fresh budget)"
jq -c '.omp_engines["omp:opencode"].slots |= map(if .slot == "glm" then .budget = {window_hours:1,max_calls:2,max_usd:null} elif .slot == "flash" then .budget = {window_hours:null,max_calls:null,max_usd:1.0} else . end)' \
  "$SHIPPED" > "$d/routing.json"
caps "$d" count "${GLM[@]}" >/dev/null
caps "$d" count "${GLM[@]}" >/dev/null
expect_not 'within max_calls: not capped' caps "$d" status "${GLM[@]}"
caps "$d" count "${GLM[@]}" >/dev/null
expect 'over max_calls: capped' caps "$d" status "${GLM[@]}"
expect 'the cap carries the budget signal' jq -e '.["omp:opencode/glm/glm-5.3"].signal == "budget"' "$d/state/omp-caps.json"
caps "$d" clear "${GLM[@]}" >/dev/null
jq -c '.["omp:opencode/glm"].start = ((now | floor) - 7200)' "$d/state/omp-counts.json" > "$d/c" && mv "$d/c" "$d/state/omp-counts.json"
caps "$d" count "${GLM[@]}" >/dev/null
expect_not 'a spent window resets the counter' caps "$d" status "${GLM[@]}"
expect 'the counter restarted at one call' jq -e '.["omp:opencode/glm"].calls == 1' "$d/state/omp-counts.json"
FLASH=(omp:opencode flash deepseek-v4.1-flash)
caps "$d" count "${FLASH[@]}" 0.6 >/dev/null
expect_not 'within max_usd: not capped' caps "$d" status "${FLASH[@]}"
caps "$d" count "${FLASH[@]}" 0.6 >/dev/null
expect 'over max_usd: capped' caps "$d" status "${FLASH[@]}"
d="$(fresh unlimited)"
for _ in 1 2 3 4 5; do caps "$d" count "${ARGON[@]}" 9 >/dev/null; done
expect_not 'null budget is unlimited' caps "$d" status "${ARGON[@]}"
expect_not 'count rejects a bad usd' caps "$d" count "${ARGON[@]}" abc

# Concurrency: ten parallel marks all land, and the file stays valid.
d="$(fresh parallel)"
for i in 1 2 3 4 5 6 7 8 9 10; do caps "$d" mark omp:opencode argon "m$i" +1h 429 >/dev/null & done
wait
expect 'ten concurrent marks all survive' jq -e 'length == 10' "$d/state/omp-caps.json"
expect 'no lock or temp file is left behind' test -z "$(find "$d/state" -mindepth 1 -maxdepth 1 \( -name '.lock' -o -name '.tmp.*' \))"

# A lock whose holder died is taken over; a broken state file stops it.
d="$(fresh stale)"
mkdir -p "$d/state/.lock"
echo 999999 > "$d/state/.lock/pid"
expect 'a stale lock is taken over' caps "$d" mark "${ARGON[@]}" +1h 429
d="$(fresh broken)"
mkdir -p "$d/state"
echo '{"x":' > "$d/state/omp-caps.json"
expect_not 'a broken state file is refused' caps "$d" status
expect_not 'usage error' caps "$d" nonsense

[ "$FAILS" -eq 0 ] && echo "omp-caps-smoke: all passed" || { echo "omp-caps-smoke: $FAILS FAIL"; exit 1; }

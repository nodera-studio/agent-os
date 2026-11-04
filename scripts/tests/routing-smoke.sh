#!/bin/bash
# routing-smoke.sh — smoke test for .claude/scripts/routing.sh (Bash 3.2, no network).
#
# Usage: /bin/bash .claude/scripts/tests/routing-smoke.sh
# Cases: default only, override present, override for one key only, unknown key (exit 2),
# broken JSON (exit 2), a default without a decision key. Every case runs twice: with jq, and with node only (a PATH without jq).
# Prints ok/FAIL per case and exits 1 on any FAIL.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROUTING="$HERE/../routing.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/routing-smoke.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# A PATH with node and the few tools routing.sh needs, but no jq.
NOJQ="$TMP/bin-nojq"
mkdir -p "$NOJQ"
for t in node dirname; do
  p="$(command -v "$t")" || { echo "FAIL: $t not installed"; exit 1; }
  ln -s "$p" "$NOJQ/$t"
done

DEFAULT_JSON='{"implementation":"claude","ui":"impl-coder-ui","review":["claude","codex"],
"heavy_concurrency":8,"decision":"0a1b2c3d","decided":"2026-01-01"}'

# setup <case>: a fresh routing dir with the default file; prints its path.
setup() {
  local d="$TMP/$1"
  mkdir -p "$d/auto-mode"
  printf '%s\n' "$DEFAULT_JSON" >"$d/routing.json"
  printf '%s\n' "$d"
}

# check <name> <engine-path|""> <dir> <key> <want-exit> <want-stdout> <want-stderr-substring>
check() {
  local name="$1" path="$2" dir="$3" key="$4" want_rc="$5" want_out="$6" want_err="$7"
  local out err rc
  if [ -n "$path" ]; then
    out="$(env PATH="$path" HARNESS_ROUTING_DIR="$dir" /bin/bash "$ROUTING" "$key" 2>"$TMP/err")"
  else
    out="$(env HARNESS_ROUTING_DIR="$dir" /bin/bash "$ROUTING" "$key" 2>"$TMP/err")"
  fi
  rc=$?
  err="$(cat "$TMP/err")"
  case "$err" in *"$want_err"*) ;; *) rc="stderr-mismatch:$rc" ;; esac
  if [ "$rc" = "$want_rc" ] && [ "$out" = "$want_out" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit=$rc (want $want_rc) stdout=[$out] (want [$want_out]) stderr=[$err] (want *$want_err*)"
    FAILS=$((FAILS + 1))
  fi
}

for engine in jq node; do
  if [ "$engine" = jq ]; then
    command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed"; FAILS=$((FAILS + 1)); continue; }
    P=""
  else
    P="$NOJQ"
  fi

  # (a) default only.
  d="$(setup "$engine-default")"
  check "$engine: default only, string" "$P" "$d" implementation 0 claude "source=default decision=0a1b2c3d"
  check "$engine: default only, array" "$P" "$d" review 0 "claude codex" "source=default decision=0a1b2c3d"
  check "$engine: default only, number" "$P" "$d" heavy_concurrency 0 8 "source=default"

  # (b) override present.
  d="$(setup "$engine-override")"
  printf '%s\n' '{"implementation":"codex","review":["codex"],"decision":"abc12345"}' \
    >"$d/auto-mode/routing.json"
  check "$engine: override present" "$P" "$d" implementation 0 codex "source=override decision=abc12345"
  check "$engine: override array" "$P" "$d" review 0 codex "source=override decision=abc12345"

  # (c) override for one key only: other keys still come from the default.
  d="$(setup "$engine-onekey")"
  printf '%s\n' '{"ui":"impl-coder-claude","decision":"def67890"}' >"$d/auto-mode/routing.json"
  check "$engine: one-key override, that key" "$P" "$d" ui 0 impl-coder-claude "source=override decision=def67890"
  check "$engine: one-key override, other key" "$P" "$d" implementation 0 claude "source=default decision=0a1b2c3d"

  # (d) unknown key: exit 2, nothing on stdout.
  d="$(setup "$engine-unknown")"
  check "$engine: unknown key" "$P" "$d" nonesuch 2 "" "unknown key: nonesuch"
  printf '%s\n' '{"ui":"impl-coder-ui"}' >"$d/auto-mode/routing.json"
  check "$engine: unknown key with override" "$P" "$d" nonesuch 2 "" "unknown key: nonesuch"

  # (e) broken JSON: exit 2 in the default, and in an override (never falls back).
  d="$(setup "$engine-broken")"
  printf '%s\n' '{"implementation": "claude",' >"$d/routing.json"
  check "$engine: broken default" "$P" "$d" implementation 2 "" "broken JSON"
  d="$(setup "$engine-broken-override")"
  printf '%s\n' '{"implementation": ' >"$d/auto-mode/routing.json"
  check "$engine: broken override" "$P" "$d" implementation 2 "" "broken JSON"
  d="$(setup "$engine-missing")"
  rm "$d/routing.json"
  check "$engine: missing default" "$P" "$d" implementation 2 "" "missing or unreadable"

  # (f) a default without a decision key prints decision=none.
  d="$(setup "$engine-nodecision")"
  printf '%s\n' '{"implementation":"claude"}' >"$d/routing.json"
  check "$engine: no decision key" "$P" "$d" implementation 0 claude "source=default decision=none"
done

# --- routing.sh engines <role> [--have <engine>...] (node; the resolver is lib/routing-engines.mjs) ---
SHIPPED="$HERE/../../routing.json"
T=$(printf '\t')
CODEX_ROW="omp:codex${T}glen-harness-codex${T}openai-codex${T}gpt-6.1-sol${T}high${T}true${T}-${T}omp:codex${T}-${T}high"
ARGON_ROW="omp:opencode${T}glen-harness-opencode${T}opencode-go${T}gemini-4-argon${T}-${T}true${T}qwen3.8-max${T}omp:opencode/argon${T}-${T}high"
FUTURE=2999-01-01T00:00:00Z PAST=2000-01-01T00:00:00Z

# esetup <case>: a routing dir holding a copy of the shipped routing.json.
esetup() {
  local d="$TMP/$1"
  mkdir -p "$d/auto-mode" "$d/state"
  cp "$SHIPPED" "$d/routing.json"
  printf '%s\n' "$d"
}
# check_eng <name> <path|""> <dir> <want-exit> <want-stdout> <want-stderr-substring> <engines args...>
check_eng() {
  local name="$1" path="$2" dir="$3" want_rc="$4" want_out="$5" want_err="$6" out err rc
  shift 6
  if [ -n "$path" ]; then
    out="$(env PATH="$path" HARNESS_ROUTING_DIR="$dir" /bin/bash "$ROUTING" engines "$@" 2>"$TMP/err")"
  else
    out="$(env HARNESS_ROUTING_DIR="$dir" /bin/bash "$ROUTING" engines "$@" 2>"$TMP/err")"
  fi
  rc=$?
  err="$(cat "$TMP/err")"
  case "$err" in *"$want_err"*) ;; *) rc="stderr-mismatch:$rc" ;; esac
  if [ "$rc" = "$want_rc" ] && [ "$out" = "$want_out" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit=$rc (want $want_rc) stdout=[$out] (want [$want_out]) stderr=[$err] (want *$want_err*)"
    FAILS=$((FAILS + 1))
  fi
}
# caps <dir> <key>...: mark each engine/slot/model key capped until the future; "past:" prefix = expired.
caps() {
  local d="$1" k until body='{}'
  shift
  for k in "$@"; do
    until=$FUTURE
    case "$k" in past:*) until=$PAST; k="${k#past:}" ;; esac
    body="$(printf '%s' "$body" | jq -c --arg k "$k" --arg u "$until" '.[$k] = {until:$u,signal:"429"}')"
  done
  printf '%s\n' "$body" > "$d/state/omp-caps.json"
}
override() { printf '%s\n' "$2" > "$1/auto-mode/routing.json"; }

command -v node >/dev/null 2>&1 || { echo "FAIL: node not installed"; FAILS=$((FAILS + 1)); }
d="$(esetup eng-valid)"
check_eng "engines: review rows" "" "$d" 0 "$(printf '%s\n%s' "$CODEX_ROW" "$ARGON_ROW")" "source=default decision=none degraded=none" review
check_eng "engines: node-only host" "$NOJQ" "$d" 0 "$(printf '%s\n%s' "$CODEX_ROW" "$ARGON_ROW")" "degraded=none" review
check_eng "engines: claude-only role has no rows" "" "$d" 0 "" "degraded=none" tests_draft
rows="$(HARNESS_ROUTING_DIR="$d" /bin/bash "$ROUTING" engines security 2>/dev/null | awk -F'\t' 'NF != 10 { bad++ } END { print bad + 0 }')"
if [ "$rows" = 0 ]; then echo "ok   engines: every row has 10 tab-separated fields"; else echo "FAIL engines: $rows rows without 10 fields"; FAILS=$((FAILS + 1)); fi
check_eng "engines: no role" "" "$d" 2 "" "usage"
check_eng "engines: unknown role" "" "$d" 2 "" "unknown role: nonesuch" nonesuch
check_eng "engines: unknown --have engine" "" "$d" 2 "" "unknown engine in --have" review --have omp:nope
NONODE="$TMP/bin-nonode"
mkdir -p "$NONODE"
for t in jq dirname; do ln -s "$(command -v "$t")" "$NONODE/$t"; done
check_eng "engines: no node" "$NONODE" "$d" 2 "" "needs node" review

# Validation: nothing on stdout, exit 2.
d="$(esetup eng-bad-slot)"
override "$d" '{"omp_roles":{"debug":{"stakes":"normal","select":["omp:opencode/nope"]}}}'
check_eng "engines: unknown slot" "" "$d" 2 "" "unknown or ambiguous slot" debug
d="$(esetup eng-bad-engine)"
override "$d" '{"omp_roles":{"debug":{"stakes":"normal","select":["omp:zen/big"]}}}'
check_eng "engines: unknown engine" "" "$d" 2 "" "unknown engine in selector" debug
d="$(esetup eng-bad-effort)"
override "$d" '{"omp_roles":{"debug":{"stakes":"normal","select":["omp:opencode/glm:turbo"]}}}'
check_eng "engines: unknown effort suffix" "" "$d" 2 "" "unknown effort" debug
d="$(esetup eng-zen)"
override "$d" '{"omp_engines":{"omp:opencode":{"profile":"glen-harness-opencode","provider":"opencode-zen","slots":[{"slot":"glm","model":"glm-5.3","effort":"high","tools":true,"fallbacks":[]}]}}}'
check_eng "engines: Zen provider is a hard error" "" "$d" 2 "" "provider must be one of" debug
d="$(esetup eng-bad-slot-effort)"
override "$d" '{"omp_engines":{"omp:opencode":{"profile":"glen-harness-opencode","provider":"opencode-go","slots":[{"slot":"glm","model":"glm-5.3","effort":"ludicrous","tools":true,"fallbacks":[]}]}}}'
check_eng "engines: bad slot effort" "" "$d" 2 "" "effort must be" debug
d="$(esetup eng-missing)"
override "$d" '{"omp_engines":{"omp:opencode":{"profile":"glen-harness-opencode","provider":"opencode-go","slots":[{"slot":"glm","model":"glm-5.3","effort":"high","fallbacks":[]}]}}}'
check_eng "engines: incomplete entry" "" "$d" 2 "" "incomplete entry (tools)" debug
d="$(esetup eng-bad-stakes)"
override "$d" '{"omp_roles":{"debug":{"stakes":"medium","select":["claude"]}}}'
check_eng "engines: bad stakes" "" "$d" 2 "" "stakes must be" debug

# An override replaces the whole engine entry and leaves the other engine ids as the default.
d="$(esetup eng-whole)"
override "$d" '{"omp_engines":{"omp:opencode":{"profile":"glen-harness-opencode","provider":"opencode-go","slots":[{"slot":"glm","model":"glm-9","effort":"low","tools":false,"fallbacks":[]}]}},"decision":"abc12345"}'
check_eng "engines: override replaces the whole entry" "" "$d" 0 "omp:opencode${T}glen-harness-opencode${T}opencode-go${T}glm-9${T}low${T}false${T}-${T}omp:opencode/glm${T}-${T}normal" "source=default" debug
check_eng "engines: other engine ids stay default" "" "$d" 0 "$CODEX_ROW" "degraded=none" architect
override "$d" '{"omp_roles":{"debug":{"stakes":"normal","select":["omp:codex"]}},"decision":"abc12345"}'
check_eng "engines: role override" "" "$d" 0 "$(printf '%s' "$CODEX_ROW" | sed "s/omp:codex${T}-${T}high\$/omp:codex${T}-${T}normal/")" "source=override decision=abc12345" debug

# Caps: normal stakes fall to the slot's own fallback; high stakes reroute to omp:codex.
d="$(esetup eng-cap-normal)"
caps "$d" omp:opencode/glm/glm-5.3
check_eng "engines: capped slot uses its own fallback" "" "$d" 0 "omp:opencode${T}glen-harness-opencode${T}opencode-go${T}kimi-k3.1-pro${T}high${T}true${T}kimi-k3.1-pro${T}omp:opencode/glm${T}glm-5.3${T}normal" "degraded=none" debug
caps "$d" omp:opencode/glm/glm-5.3 omp:opencode/glm/kimi-k3.1-pro
check_eng "engines: every candidate capped drops the row" "" "$d" 0 "" "capped=omp:opencode/glm" debug
caps "$d" past:omp:opencode/glm/glm-5.3
check_eng "engines: an expired cap is ignored" "" "$d" 0 "omp:opencode${T}glen-harness-opencode${T}opencode-go${T}glm-5.3${T}high${T}true${T}kimi-k3.1-pro${T}omp:opencode/glm${T}-${T}normal" "degraded=none" debug
d="$(esetup eng-cap-high)"
caps "$d" omp:opencode/argon/gemini-4-argon
FLASH_ROW="omp:opencode${T}glen-harness-opencode${T}opencode-go${T}deepseek-v4.1-flash${T}low${T}true${T}glm-5.3-flash${T}omp:opencode/flash${T}-${T}high"
REROUTED="omp:codex${T}glen-harness-codex${T}openai-codex${T}gpt-6.1-sol${T}high${T}true${T}-${T}omp:opencode/argon${T}gemini-4-argon${T}high"
check_eng "engines: high stakes reroutes to omp:codex" "" "$d" 0 "$(printf '%s\n%s' "$REROUTED" "$FLASH_ROW")" "degraded=none" security
check_eng "engines: reroute is skipped when codex is already present" "" "$d" 0 "$CODEX_ROW" "degraded=2-engines" review
check_eng "engines: --have counts as present" "" "$d" 0 "$FLASH_ROW" "degraded=3-engines" security --have omp:codex
caps "$d" omp:opencode/argon/gemini-4-argon omp:opencode/flash/deepseek-v4.1-flash
check_eng "engines: codex is never counted twice" "" "$d" 0 "$REROUTED" "degraded=2-engines" security
override "$d" '{"omp_fallback":["codex"]}'
check_eng "engines: omp_fallback never yields a native codex row" "" "$d" 0 "$REROUTED" "degraded=2-engines" security

# The shipped data stays dormant: legacy keys unchanged, no native fallback.
d="$(esetup eng-legacy)"
check "legacy: review unchanged" "" "$d" review 0 "claude codex" "source=default"
check "legacy: planning unchanged" "" "$d" planning 0 "claude codex" "source=default"
check "legacy: debug unchanged" "" "$d" debug 0 "claude codex" "source=default"
check "legacy: audits unchanged" "" "$d" audits 0 "claude codex" "source=default"
check "legacy: implementation unchanged" "" "$d" implementation 0 claude "source=default"
check "legacy: ui unchanged" "" "$d" ui 0 impl-coder-ui "source=default"
check "legacy: heavy_concurrency unchanged" "" "$d" heavy_concurrency 0 8 "source=default"
check "legacy: omp_fallback is empty" "$NOJQ" "$d" omp_fallback 0 "" "source=default"
check "legacy: omp_fallback is empty (jq)" "" "$d" omp_fallback 0 "" "source=default"

check "no key argument" "" "$TMP" "" 2 "" "usage"

if [ "$FAILS" -gt 0 ]; then
  echo "routing-smoke: $FAILS FAIL"
  exit 1
fi
echo "routing-smoke: all passed"

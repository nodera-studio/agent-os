#!/usr/bin/env bash
# Engine-mode smoke (omp:codex, omp:opencode): scratch repos/homes and CLI stubs, no network, no key.
# Cases so far: the sandbox launchers accept only the registry's profile names and pass the per-run model and
# no-tools choice through. Run it inside the .claude/ project layout: scripts/tests/harness-smoke.sh does that.
set -euo pipefail
umask 077

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd -P)"
OMP_DIR="$REPO_ROOT/.claude/omp"
# Same scratch rule as omp-engine-smoke.sh: a private parent, never /tmp (strict ancestor checks).
if [ "$(uname -s)" = Darwin ]; then smoke_parent="${TMPDIR:-/tmp}"; else smoke_parent="$HOME"; fi
WORK="$(mktemp -d "$smoke_parent/glen-omp-engines-smoke.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tmp" "$WORK/home" "$WORK/bin"
export TMPDIR="$WORK/tmp"
STDOUT="$WORK/stdout" STDERR="$WORK/stderr"
CASES=0 FAILURES=0 CODE=0

assert() {
  local label="$1"
  shift
  CASES=$((CASES + 1))
  if "$@" >/dev/null 2>&1; then
    printf 'PASS %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label" >&2
    FAILURES=$((FAILURES + 1))
  fi
}
assert_eq() {
  assert "$1" test "$2" = "$3"
  [ "$2" = "$3" ] || printf '     got [%s] want [%s]\n' "$2" "$3" >&2
}
assert_exit() { assert_eq "$1" "$CODE" "$2"; }
assert_contains() { assert "$1" grep -Fq -- "$2" "$3"; }
run() {
  if "$@" > "$STDOUT" 2> "$STDERR"; then CODE=0; else CODE="$?"; fi
}

# --- Step 7: the launchers carry the exact profile names, and only those ---
# shellcheck source=../../omp/profiles.sh
. "$OMP_DIR/profiles.sh"
for launcher in omp-sandboxed.sh omp-sandboxed-linux.sh; do
  for name in $(profile_names); do
    assert "$launcher names $name" grep -Fq -- "$name" "$OMP_DIR/$launcher"
  done
  assert "$launcher has no profile glob" test "$(grep -Ec 'glen-harness-\*|glen-harness\*' "$OMP_DIR/$launcher")" -eq 0
done

if [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$WORK/launch/run"
  LHOME="$WORK/launch/home"
  mkdir -p "$LHOME/.omp/natives"
  # A fake sandbox-exec that skips `-f profile` and runs the command, and an omp that records its argv.
  cat > "$WORK/bin/sandbox-exec" <<'STUB'
#!/bin/bash
[ "$1" = -f ] && [ -f "$2" ] || exit 99
shift 2
exec "$@"
STUB
  cat > "$WORK/bin/omp" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$SMOKE_ARGV"
STUB
  chmod +x "$WORK/bin/sandbox-exec" "$WORK/bin/omp"
  export SMOKE_ARGV="$WORK/launch/argv"
  launch() {
    # launch <profile-dir-name> [env...]: run the real launcher against $LHOME/.omp/profiles/<name>/agent.
    local name="$1"
    shift
    env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$LHOME" TMPDIR="$WORK/tmp" SMOKE_ARGV="$SMOKE_ARGV" \
      OMP_SANDBOX_RUN_ROOT="$WORK/launch/run" OMP_REAL_BIN="$WORK/bin/omp" \
      OMP_PROFILE_AGENT_DIR="$LHOME/.omp/profiles/$name/agent" "$@" \
      /bin/bash "$OMP_DIR/omp-sandboxed.sh" --mode rpc
  }
  for name in $(profile_names); do
    mkdir -p "$LHOME/.omp/profiles/$name/agent"
    : > "$SMOKE_ARGV"
    run launch "$name"
    assert_exit "launcher accepts $name" 0
    assert_eq "launcher runs omp for $name" "$(cat "$SMOKE_ARGV")" $'--mode\nrpc'
  done
  for name in glen-harness-probe glen-harness-evil 'glen-harness-*' glen-harness-codex2 glen-harness- glen-harnes ''; do
    mkdir -p "$LHOME/.omp/profiles/${name:-empty}/agent" 2>/dev/null || true
    : > "$SMOKE_ARGV"
    run launch "$name"
    assert_exit "launcher refuses profile '$name'" 1
    assert "launcher refusal for '$name' names the allowlist" grep -Fq 'not on the allowlist' "$STDERR"
    assert "launcher refusal for '$name' runs nothing" test ! -s "$SMOKE_ARGV"
  done
  # An allowed name in the wrong place is still refused.
  mkdir -p "$WORK/launch/elsewhere/glen-harness-codex/agent"
  run env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$LHOME" TMPDIR="$WORK/tmp" SMOKE_ARGV="$SMOKE_ARGV" \
    OMP_SANDBOX_RUN_ROOT="$WORK/launch/run" OMP_REAL_BIN="$WORK/bin/omp" \
    OMP_PROFILE_AGENT_DIR="$WORK/launch/elsewhere/glen-harness-codex/agent" /bin/bash "$OMP_DIR/omp-sandboxed.sh" --mode rpc
  assert_exit 'launcher refuses an allowed name outside profiles/' 1
  # The per-run model and no-tools choice reach omp, validated.
  run launch glen-harness-opencode OMP_STARTUP_MODEL=opencode-go/glm-5.3:high OMP_NO_TOOLS=1
  assert_exit 'launcher passes a startup model and --no-tools' 0
  assert_eq 'launcher appends --model and --no-tools' "$(tr '\n' ' ' < "$SMOKE_ARGV")" '--mode rpc --model opencode-go/glm-5.3:high --no-tools '
  run launch glen-harness-opencode 'OMP_STARTUP_MODEL=x;rm -rf /'
  assert_exit 'launcher refuses a startup model with shell characters' 1
else
  printf 'NOTE launcher run cases skipped: they need macOS sandbox-exec\n'
fi

# --- Step 5: engine-mode dispatch (stub glen, stub omp behind the real launcher and a fake sandbox-exec) ---
if [ "$(uname -s)" = Darwin ]; then
ENGINE_SH="$REPO_ROOT/.claude/scripts/omp-engine.sh"
CAPS_SH="$REPO_ROOT/.claude/scripts/omp-caps.sh"
EHOME="$WORK/home"
for name in glen-harness-codex glen-harness-opencode; do
  mkdir -p "$EHOME/.omp/profiles/$name/agent"
  printf 'modelRoles:\n  default: saved/default\n' > "$EHOME/.omp/profiles/$name/agent/config.yml"
done
mkdir -p "$EHOME/.omp/natives"
DISPATCH_BIN="$WORK/dispatch-bin"
mkdir -p "$DISPATCH_BIN"
FAKE_REAL_DATE="$(command -v date)"
export FAKE_REAL_DATE
cat > "$DISPATCH_BIN/date" <<'STUB'
#!/bin/bash
set -eu
if [ "$*" = '+%s' ]; then cat "$FAKE_GLEN_STATE/clock"; else exec "$FAKE_REAL_DATE" "$@"; fi
STUB
cat > "$DISPATCH_BIN/sleep" <<'STUB'
#!/bin/bash
set -eu
[ "$*" = 60 ] || exit 99
printf '60\n' >> "$FAKE_GLEN_STATE/sleeps"
printf '%s\n' "$(( $(cat "$FAKE_GLEN_STATE/clock") + 60 ))" > "$FAKE_GLEN_STATE/clock"
STUB
# omp behind the launcher answers only readiness queries; the models it lists can be trimmed per case.
cat > "$WORK/bin/omp" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SMOKE_OMP_CALLS"
case "$*" in
  *' models openai-codex --json') printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6.1-sol"}]}' ;;
  *' models opencode-go --json')
    for id in gemini-4-argon qwen3.8-max glm-5.3 kimi-k3.1-pro deepseek-v4.1-flash glm-5.3-flash; do
      [ "$id" != "${SMOKE_OMIT_MODEL:-}" ] && printf '%s\n' "$id"
    done | jq -Rcn '{models: [inputs | {provider:"opencode-go",id:.}]}' ;;
  *' usage --provider '*' --json') cat "$FAKE_GLEN_STATE/usage.json" 2>/dev/null || printf '%s\n' '{"accounts":[]}' ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$DISPATCH_BIN/date" "$DISPATCH_BIN/sleep" "$WORK/bin/omp"
export SMOKE_OMP_CALLS="$WORK/omp-calls"
: > "$SMOKE_OMP_CALLS"

ESRC="$WORK/engine-source"
mkdir -p "$ESRC"
git -C "$ESRC" init -q --initial-branch=main
printf 'fixture\n' > "$ESRC/tracked"
git -C "$ESRC" add .
git -C "$ESRC" -c user.name='Glen smoke' -c user.email='smoke@example.invalid' -c core.hooksPath=/dev/null \
  -c commit.gpgsign=false commit --no-gpg-sign -qm fixture
mkdir -p "$WORK/eruns"
printf 'Debug fixture\n' > "$WORK/brief.md"

# engine_case <name> [provider model]: a fresh glen state, routing dir (shipped data, empty caps) and clock.
engine_case() {
  STATE="$WORK/eruns/$1" RDIR="$WORK/eruns/$1-routing" CASE_PROVIDER="${2:-openai-codex}" CASE_MODEL="${3:-gpt-6.1-sol}"
  mkdir -p "$STATE" "$RDIR/state" "$RDIR/auto-mode"
  cp "$REPO_ROOT/.claude/routing.json" "$RDIR/routing.json"
  printf '100000\n' > "$STATE/clock"
  : > "$STATE/plan.jsonl" 
  : > "$STATE/sleeps"
  CASE_OUT="$STATE/answer.md" CASE_DEADLINE=15m CASE_MODE=review
  ANSWER=$'## omp review\nAPPROVE\nMnemosyne: unavailable'
  transcript j0000001 "$CASE_PROVIDER" "$CASE_MODEL"
  transcript j0000002 "$CASE_PROVIDER" "$CASE_MODEL"
}
transcript() {
  jq -cn --arg provider "$2" --arg model "$3" \
    '{type:"message",message:{role:"assistant",model:$model,provider:$provider,usage:{input:1,output:1,totalTokens:2,cost:{total:0}}}}' \
    > "$STATE/session-$1.jsonl"
}
envelope() { # envelope <status> <job>
  jq -cn --arg status "$1" --arg answer "$ANSWER" --arg job "$2" --arg state "$STATE" '
    {v:1,ok:true,data:{status:$status,assistant_text:$answer,command_output:[],delivered_as:"prompt",forked:null,
      session_settled:true,stop_reason:null,
      job:{id:"00000000-0000-7000-8000-000000000001",handle:$job,status:"completed",route:"new",deliver_as:"auto",
        delivered_as:"prompt",session_id:null,session_handle:("a"+$job[1:]),actual_session_id:null,
        created_at:"2026-10-30T00:00:00Z",updated_at:"2026-10-30T00:00:00Z",elapsed_ms:0},
      session:{id:null,handle:("a"+$job[1:]),path:($state+"/session-"+$job+".jsonl")},
      replies:[{v:1,text:"fixture reply",final:true,id:"fixture-reply",job_id:$job,request_id:null,session_id:null,
        tool_call_id:"fixture-call",at:"2026-10-30T00:00:00Z"}]}}'
}
failure() { # failure <job> <code> <message>: a failed job envelope (glen exit 7)
  jq -cn --arg job "$1" --arg code "$2" --arg message "$3" '
    {v:1,ok:false,error:{code:"job_failed",message:$message,details:{status:"failed",
      job:{handle:$job,status:"failed"},forked:null,error:{code:$code,message:$message},request_id:null}}}'
}
step() { # step <command> <exit> <envelope-json>
  jq -cn --arg c "$1" --argjson code "$2" --argjson e "$3" '{command:$c,exit:$code,envelope:$e}' >> "$STATE/plan.jsonl"
}
# edispatch [extra engine args...]: run the engine with the case's plan; args after the case defaults win last.
edispatch() {
  local -a mode_args=(--uncommitted)
  [ "$CASE_MODE" = review ] || mode_args=(--brief "$WORK/brief.md")
  jq -s . "$STATE/plan.jsonl" > "$STATE/steps.json"
  rm -f "$STATE/count" "$STATE/calls.jsonl"
  run env HOME="$EHOME" PI_CONFIG_DIR=.omp GLEN_OMP_ENGINE=on HARNESS_ROUTING_DIR="$RDIR" FAKE_GLEN_STATE="$STATE" \
    PATH="$DISPATCH_BIN:$WORK/bin:$PATH" GLEN_BIN="$TEST_DIR/support/glen" OMP_PROBE_RESULT="${CASE_PROBE:-$WORK/none.json}" \
    ${CASE_ENV[@]+"${CASE_ENV[@]}"} \
    /bin/bash "$ENGINE_SH" "$CASE_MODE" --repo "$ESRC" "${mode_args[@]}" --out "$CASE_OUT" --deadline "$CASE_DEADLINE" "$@"
}
CASE_ENV=() CASE_PROBE=''
caps_mark() { HARNESS_ROUTING_DIR="$RDIR" /bin/bash "$CAPS_SH" mark "$@" >/dev/null; }
calls() { jq -rs "$1" "$STATE/calls.jsonl"; }
result() { jq -r "$1" "$STDOUT"; }

# E1: omp:codex review, provenance and the overlay.
engine_case codex-ok
step send 0 "$(envelope completed j0000001)"
edispatch --engine omp:codex --role review
assert_exit 'codex review exits 0' 0
assert_eq 'codex review status' "$(result .status)" ok
assert_eq 'result carries the engine id' "$(result .engine)" omp:codex
assert_eq 'result carries the profile' "$(result .profile)" glen-harness-codex
assert_eq 'result carries the slot' "$(result .slot)" codex
assert 'result carries requested and observed' jq -e '.requested == {provider:"openai-codex",model:"gpt-6.1-sol",effort:"high"}
  and .observed == {provider:"openai-codex",model:"gpt-6.1-sol"}' "$STDOUT"
assert 'result carries routing provenance' jq -e '.routing == {role:"review",source:"default",decision:"none",substituted_from:null} and .degraded == null' "$STDOUT"
assert_eq 'glen ran under the codex profile' "$(calls '.[0].profile')" glen-harness-codex
assert_eq 'the effort reaches glen as --thinking' "$(calls '.[0].argv | .[index("--thinking") + 1]')" high
overlay="$(result .run_dir)/model-overlay.yml"
assert_contains 'the per-run overlay names provider/model:effort' 'default: openai-codex/gpt-6.1-sol:high' "$overlay"
assert_eq 'policy and overlay are both config files' "$(calls '.[0].policy | split(":") | length')" 2
assert_eq 'the overlay is listed after the policy' "$(calls '.[0].policy | split(":")[1] | endswith("model-overlay.yml")')" true
assert_eq 'the readiness probe queried the engine provider' "$(grep -c -- '--profile glen-harness-codex models openai-codex --json' "$SMOKE_OMP_CALLS")" 1
assert 'the saved profile default is untouched' grep -Fq 'default: saved/default' "$EHOME/.omp/profiles/glen-harness-codex/agent/config.yml"

# E2: omp:opencode needs the probe (AC-026) unless dev-overridden; argon has no effort level.
engine_case unprobed openai-codex gpt-6.1-sol
transcript j0000001 opencode-go gemini-4-argon
step send 0 "$(envelope completed j0000001)"
edispatch --engine omp:opencode --slot argon --role review
assert_exit 'unprobed opencode exits 3' 3
assert_eq 'unprobed reason' "$(result .reason)" unprobed
assert_eq 'unprobed status' "$(result .status)" skipped
assert 'unprobed dispatch never reached glen' test ! -e "$STATE/count"
CASE_ENV=(GLEN_OMP_UNPROBED_OK=1)
engine_case argon-ok opencode-go gemini-4-argon
step send 0 "$(envelope completed j0000001)"
edispatch --engine omp:opencode --slot argon --role review
assert_exit 'argon review exits 0 with the dev override' 0
assert 'argon result: no effort requested' jq -e '.requested == {provider:"opencode-go",model:"gemini-4-argon",effort:null} and .slot == "argon"' "$STDOUT"
assert_eq 'argon sends no --thinking' "$(calls '.[0].argv | index("--thinking")')" null
assert_contains 'argon overlay has no effort suffix' 'default: opencode-go/gemini-4-argon' "$(result .run_dir)/model-overlay.yml"
CASE_ENV=()
engine_case probed opencode-go gemini-4-argon
printf '{"ids":{"gemini-4-argon":true},"launch_mechanism":"overlay"}\n' > "$WORK/probe-ok.json"
CASE_PROBE="$WORK/probe-ok.json"
step send 0 "$(envelope completed j0000001)"
edispatch --engine omp:opencode --slot argon --role review
assert_exit 'a probe-result file lifts the unprobed gate' 0
CASE_PROBE=''

# E3: provider and model gates (AC-020, AC-022).
engine_case wrong-provider openai-codex gpt-6.1-sol
transcript j0000001 cursor gpt-6.1-sol
step send 0 "$(envelope completed j0000001)"
edispatch --engine omp:codex --role review
assert_exit 'a run on another provider exits 4' 4
assert_contains 'the provider refusal names both providers' 'ran on cursor, not openai-codex' "$STDOUT"
engine_case wrong-model openai-codex other-model
step send 0 "$(envelope completed j0000001)"
edispatch --engine omp:codex --role review
assert_exit 'a run on an unlisted model exits 4' 4
assert_contains 'the model refusal names both models' 'ran model other-model, requested gpt-6.1-sol' "$STDOUT"
CASE_ENV=(GLEN_OMP_UNPROBED_OK=1)
engine_case fallback-model opencode-go qwen3.8-max
step send 0 "$(envelope completed j0000001)"
edispatch --engine omp:opencode --slot argon --role review
assert_exit "a slot's own fallback model is accepted" 0

# E4: argument and routing errors.
engine_case usage
edispatch --engine omp:codex
assert_exit 'an engine without --role is a usage error' 2
edispatch --role review
assert_exit '--role without an engine is a usage error' 2
edispatch --engine omp:cursor --role review
assert_exit 'an unknown engine is a usage error' 2
edispatch --engine omp:codex --role review --slot
assert_exit 'a flag without a value is a usage error' 2
edispatch --engine omp:opencode --slot flash --role review
assert_exit 'a slot the role does not select is refused' 2
assert_contains 'the refusal names the role and slot' 'role review does not select omp:opencode/flash' "$STDOUT"
edispatch --engine omp:codex --role nonesuch
assert_exit 'an unknown role fails closed' 4
printf '%s\n' '{"omp_engines":{"omp:opencode":{"profile":"glen-harness-opencode","provider":"opencode-zen","slots":[{"slot":"argon","model":"x","effort":null,"tools":true,"fallbacks":[]}]}}}' > "$RDIR/auto-mode/routing.json"
edispatch --engine omp:codex --role review
assert_exit 'a Zen provider anywhere in the data fails closed' 4
assert_contains 'the failure names the routing error' 'routing.sh engines failed' "$STDOUT"
assert 'none of these refusals reached glen' test ! -e "$STATE/count"
engine_case off
CASE_ENV=(GLEN_OMP_ENGINE=off)
edispatch --engine omp:codex --role review
CASE_ENV=(GLEN_OMP_UNPROBED_OK=1)
assert_exit 'GLEN_OMP_ENGINE=off disables engine dispatch' 3

# E5: caps already recorded (AC-011 to AC-014).
engine_case sub-glm opencode-go kimi-k3.1-pro
caps_mark omp:opencode glm glm-5.3 +1h 429
ANSWER=$'## Root Cause\nFixture'
step send 0 "$(envelope completed j0000001)"
CASE_MODE=debug
edispatch --engine omp:opencode --slot glm --role debug
assert_exit 'a capped glm slot runs on its fallback' 0
assert 'substitution is recorded' jq -e '.requested.model == "kimi-k3.1-pro" and .routing.substituted_from == "glm-5.3"' "$STDOUT"
assert_contains 'the overlay names the fallback' 'default: opencode-go/kimi-k3.1-pro:high' "$(result .run_dir)/model-overlay.yml"
engine_case all-capped opencode-go glm-5.3
caps_mark omp:opencode glm glm-5.3 +1h 429
caps_mark omp:opencode glm kimi-k3.1-pro +1h 429
CASE_MODE=debug
edispatch --engine omp:opencode --slot glm --role debug
assert_exit 'every candidate capped exits 3' 3
assert_eq 'reason is capped' "$(result .reason)" capped
assert 'no fallback to Zen or native Codex: glen never ran' test ! -e "$STATE/count"
engine_case high-cap opencode-go gemini-4-argon
caps_mark omp:opencode argon gemini-4-argon +1h 429
CASE_MODE=review
edispatch --engine omp:opencode --slot argon --role security
assert_exit 'a capped high-stakes slot exits 3' 3
assert_eq 'it asks for omp:codex, not the slot fallback' "$(result .reroute)" omp:codex
assert 'the slot fallback was not used' test ! -e "$STATE/count"
engine_case degraded opencode-go gemini-4-argon
caps_mark omp:opencode argon gemini-4-argon +1h 429
edispatch --engine omp:opencode --slot argon --role review
assert_exit 'codex already present: exit 3 again' 3
assert_eq 'the degradation is disclosed' "$(result .degraded)" 2-engines
assert_eq 'and nothing is rerouted' "$(result .reroute)" null

# E6: a usage limit during the run (AC-010, AC-025).
engine_case limit-normal opencode-go kimi-k3.1-pro
transcript j0000002 opencode-go kimi-k3.1-pro
ANSWER=$'## Root Cause\nFixture'
step send 7 "$(failure j0000001 GoUsageLimitError 'HTTP 429 GoUsageLimitError: go usage limit reached')"
step send 0 "$(envelope completed j0000002)"
CASE_MODE=debug
edispatch --engine omp:opencode --slot glm --role debug
assert_exit 'a usage limit falls back inside the slot' 0
assert_eq 'two sends, no wait' "$(cat "$STATE/count")" 2
assert_eq 'no 60 second sleep on a usage limit' "$(wc -l < "$STATE/sleeps" | tr -d ' ')" 0
assert 'the capped model is recorded' sh -c "HARNESS_ROUTING_DIR='$RDIR' /bin/bash '$CAPS_SH' status omp:opencode glm glm-5.3"
assert 'the result names the substitution' jq -e '.requested.model == "kimi-k3.1-pro" and .routing.substituted_from == "glm-5.3"' "$STDOUT"
engine_case limit-402 opencode-go kimi-k3.1-pro
transcript j0000002 opencode-go kimi-k3.1-pro
step send 7 "$(failure j0000001 payment_required 'HTTP 402 Insufficient account funds')"
step send 0 "$(envelope completed j0000002)"
edispatch --engine omp:opencode --slot glm --role debug
assert_exit 'insufficient funds is a cap too' 0
assert_eq 'recorded with the 402 signal' "$(jq -r '.["omp:opencode/glm/glm-5.3"].signal' "$RDIR/state/omp-caps.json")" 402
engine_case limit-high opencode-go gemini-4-argon
step send 7 "$(failure j0000001 GoUsageLimitError 'GoUsageLimitError')"
CASE_MODE=review
edispatch --engine omp:opencode --slot argon --role security
assert_exit 'a usage limit on a high-stakes role exits 3' 3
assert_eq 'and reroutes to omp:codex' "$(result .reroute)" omp:codex
assert_eq 'without a second send' "$(cat "$STATE/count")" 1
engine_case limit-late opencode-go kimi-k3.1-pro
step send 7 "$(failure j0000001 GoUsageLimitError 'GoUsageLimitError')"
CASE_MODE=debug
edispatch --engine omp:opencode --slot glm --role debug --deadline 200s
assert_exit 'under 300 s left there is no fallback attempt' 3
assert_eq 'one send only' "$(cat "$STATE/count")" 1
engine_case limit-rate-limited opencode-go kimi-k3.1-pro
transcript j0000002 opencode-go kimi-k3.1-pro
printf '%s\n' '{"accounts":[{"status":"rate-limited"}]}' > "$STATE/usage.json"
step send 7 "$(failure j0000001 rate_limit '429 too many requests')"
step send 0 "$(envelope completed j0000002)"
edispatch --engine omp:opencode --slot glm --role debug
assert_exit 'a plain 429 with omp usage rate-limited is a cap' 0
assert_eq 'it carries the usage signal' "$(jq -r '.["omp:opencode/glm/glm-5.3"].signal' "$RDIR/state/omp-caps.json")" usage
engine_case limit-generic opencode-go glm-5.3
transcript j0000002 opencode-go glm-5.3
step send 7 "$(failure j0000001 rate_limit '429 too many requests')"
step send 0 "$(envelope completed j0000002)"
edispatch --engine omp:opencode --slot glm --role debug
assert_exit 'a plain 429 keeps the generic retry' 0
assert_eq 'which sleeps 60 seconds once' "$(wc -l < "$STATE/sleeps" | tr -d ' ')" 1
assert 'and records no cap' test ! -s "$RDIR/state/omp-caps.json"

# E7: the model-selection mechanisms, the key scrub, and no-tools.
engine_case mech opencode-go glm-5.3
ANSWER=$'## Root Cause\nFixture'
step send 0 "$(envelope completed j0000001)"
CASE_ENV=(GLEN_OMP_UNPROBED_OK=1 OMP_MODEL_MECH=startup_arg OPENCODE_API_KEY=smoke-not-a-key)
CASE_MODE=debug
edispatch --engine omp:opencode --slot glm --role debug
assert_exit 'startup_arg dispatch succeeds' 0
assert_eq 'the model reaches the launcher by env' "$(calls '.[0].startup_model')" 'opencode-go/glm-5.3:high'
assert_eq 'and the policy is the only config file' "$(calls '.[0].policy | split(":") | length')" 1
assert_eq 'the opencode engine keeps the key' "$(calls '.[0].has_opencode_key')" true
engine_case mech-glen opencode-go glm-5.3
step model 0 '{"v":1,"ok":true}'
step send 0 "$(envelope completed j0000001)"
CASE_ENV=(GLEN_OMP_UNPROBED_OK=1 OMP_MODEL_MECH=glen_model)
edispatch --engine omp:opencode --slot glm --role debug
assert_exit 'glen_model dispatch succeeds' 0
assert_eq 'glen model runs first, with the spec' "$(calls '.[0].argv | join(" ")')" '--profile glen-harness-opencode model @new opencode-go/glm-5.3:high'
engine_case mech-slot opencode-go glm-5.3
CASE_ENV=(GLEN_OMP_UNPROBED_OK=1 OMP_MODEL_MECH=profile_per_slot)
edispatch --engine omp:opencode --slot glm --role debug
assert_exit 'profile_per_slot without a registered profile skips' 3
engine_case no-tools opencode-go glm-5.3
jq -c '.omp_engines["omp:opencode"].slots |= map(if .slot == "glm" then .tools = false else . end)' "$REPO_ROOT/.claude/routing.json" > "$RDIR/routing.json"
step send 0 "$(envelope completed j0000001)"
CASE_ENV=(GLEN_OMP_UNPROBED_OK=1 OPENCODE_API_KEY=smoke-not-a-key)
edispatch --engine omp:opencode --slot glm --role debug
assert_exit 'a tools:false slot dispatches' 0
assert_eq 'tools:false reaches the launcher as OMP_NO_TOOLS' "$(calls '.[0].no_tools')" 1
engine_case key-scrub openai-codex gpt-6.1-sol
ANSWER=$'## omp review\nAPPROVE\nMnemosyne: unavailable'
step send 0 "$(envelope completed j0000001)"
CASE_ENV=(OPENCODE_API_KEY=smoke-not-a-key)
CASE_MODE=review
edispatch --engine omp:codex --role review
assert_exit 'codex dispatch with a key in the environment' 0
assert_eq 'the codex engine never sees the OpenCode key' "$(calls '.[0].has_opencode_key')" false

# E8: probe mode with an engine, and no shared-profile mutation under concurrent different-model runs (AC-091).
engine_case probe
CASE_ENV=()
run env HOME="$EHOME" PI_CONFIG_DIR=.omp GLEN_OMP_ENGINE=on HARNESS_ROUTING_DIR="$RDIR" PATH="$DISPATCH_BIN:$WORK/bin:$PATH" \
  FAKE_GLEN_STATE="$STATE" GLEN_BIN="$TEST_DIR/support/glen" /bin/bash "$ENGINE_SH" probe --engine omp:codex --role review
assert_exit 'probe --engine omp:codex is ready' 0
assert_eq 'probe reports the requested model' "$(result .model)" openai-codex/gpt-6.1-sol
run env HOME="$EHOME" PI_CONFIG_DIR=.omp GLEN_OMP_ENGINE=on HARNESS_ROUTING_DIR="$RDIR" PATH="$DISPATCH_BIN:$WORK/bin:$PATH" \
  FAKE_GLEN_STATE="$STATE" GLEN_BIN="$TEST_DIR/support/glen" SMOKE_OMIT_MODEL=gemini-4-argon OMP_PROBE_RESULT="$WORK/probe-ok.json" \
  /bin/bash "$ENGINE_SH" probe --engine omp:opencode --slot argon --role review
assert_exit 'probe skips when the requested model is not listed' 3
assert_contains 'and names the model' 'opencode-go/gemini-4-argon is not listed' "$STDOUT"

before="$(cat "$EHOME/.omp/profiles/glen-harness-opencode/agent/config.yml")"
engine_case par-a opencode-go glm-5.3
ANSWER=$'## Root Cause\nFixture'
step send 0 "$(envelope completed j0000001)"
A_STATE="$STATE" A_RDIR="$RDIR"
engine_case par-b opencode-go deepseek-v4.1-flash
ANSWER=$'## Root Cause\nFixture'
step send 0 "$(envelope completed j0000001)"
B_STATE="$STATE" B_RDIR="$RDIR"
jq -s . "$A_STATE/plan.jsonl" > "$A_STATE/steps.json"
jq -s . "$B_STATE/plan.jsonl" > "$B_STATE/steps.json"
for lane in a b; do
  if [ "$lane" = a ]; then slot=glm role=debug lstate="$A_STATE" lrdir="$A_RDIR"; else slot=flash role=explore lstate="$B_STATE" lrdir="$B_RDIR"; fi
  env HOME="$EHOME" PI_CONFIG_DIR=.omp GLEN_OMP_ENGINE=on GLEN_OMP_UNPROBED_OK=1 HARNESS_ROUTING_DIR="$lrdir" FAKE_GLEN_STATE="$lstate" \
    PATH="$DISPATCH_BIN:$WORK/bin:$PATH" GLEN_BIN="$TEST_DIR/support/glen" \
    /bin/bash "$ENGINE_SH" debug --repo "$ESRC" --brief "$WORK/brief.md" --out "$lstate/answer.md" --engine omp:opencode --slot "$slot" --role "$role" \
    > "$lstate/stdout" 2> "$lstate/stderr" &
done
wait
assert_eq 'concurrent different-model runs leave the shared profile config unchanged' "$(cat "$EHOME/.omp/profiles/glen-harness-opencode/agent/config.yml")" "$before"
assert_eq 'both concurrent runs succeeded' "$(jq -r .status "$A_STATE/stdout")$(jq -r .status "$B_STATE/stdout")" okok
assert_contains 'run A used its own model' 'default: opencode-go/glm-5.3:high' "$(jq -r .run_dir "$A_STATE/stdout")/model-overlay.yml"
assert_contains 'run B used its own model' 'default: opencode-go/deepseek-v4.1-flash:low' "$(jq -r .run_dir "$B_STATE/stdout")/model-overlay.yml"
fi

printf '%s cases, %s failed\n' "$CASES" "$FAILURES"
[ "$FAILURES" -eq 0 ]

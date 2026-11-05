#!/usr/bin/env bash
# Owner-run keyed probe for the omp:opencode engine. Never run by an agent.
# Usage: omp-probe-keyed.sh [--out FILE] [--evidence FILE] [--cap-sample FILE] [--dry-run]
# Needs OPENCODE_API_KEY in the environment or a stored `omp --profile glen-harness-opencode login
# opencode-go`; the key is never printed. Writes omp/probe-result.json (ids and booleans only) and a
# sanitized evidence/omp-engines/probe.md. Its absence keeps omp:opencode blocked (reason "unprobed").
# --cap-sample FILE is an authentic usage-limit error you captured earlier; a 429 cannot be forced.
set -euo pipefail
umask 077
case "$-" in *x*) echo 'omp-probe-keyed: refusing to run under xtrace (it would echo the key)' >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROFILE="${OMP_PROBE_PROFILE:-glen-harness-opencode}"
OUT="$ROOT/omp/probe-result.json" EVIDENCE="$ROOT/evidence/omp-engines/probe.md" CAP_SAMPLE='' DRY=0
# Same literal as the cap matcher in omp-engine.sh; keep the two in step.
CAP_RE='GoUsageLimitError|Insufficient account funds|HTTP 429|status.?code.?429'
ARGON=gemini-4-argon QWEN=qwen3.8-max GLM=glm-5.3 KIMI=kimi-k3.1-pro FLASH=deepseek-v4.1-flash GLMFLASH=glm-5.3-flash
IDS="$ARGON $QWEN $GLM $KIMI $FLASH $GLMFLASH"

say() { printf '%s\n' "$*"; }
die() { say "omp-probe-keyed: $*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out | --evidence | --cap-sample)
      [ "$#" -ge 2 ] || die "$1 needs a value"
      case "$1" in --out) OUT="$2" ;; --evidence) EVIDENCE="$2" ;; *) CAP_SAMPLE="$2" ;; esac
      shift 2
      ;;
    --dry-run) DRY=1; shift ;;
    --help | -h) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1 (use --help)" ;;
  esac
done
if [ "$DRY" -eq 1 ]; then
  say "would probe profile $PROFILE: model ids ($IDS), launch mechanism (overlay, --model, glen model),"
  say 'env passthrough, stored login, cap signal, tool use per slot, --no-tools'
  say "would write $OUT and $EVIDENCE"
  exit 0
fi
for tool in omp jq perl; do command -v "$tool" >/dev/null 2>&1 || die "required tool missing: $tool"; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/omp-probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
NOTES="$WORK/notes"
: > "$NOTES"
note() { printf -- '- %s\n' "$*" >> "$NOTES"; }

# Every omp call is bounded and its output stays in a file; nothing is echoed raw.
DROP_KEY=0
omp_p() {
  local seconds="$1"
  shift
  if [ "$DROP_KEY" -eq 1 ]; then
    env -u OPENCODE_API_KEY perl -e 'alarm shift @ARGV; exec @ARGV' "$seconds" omp --profile "$PROFILE" "$@" 2>&1 || return 1
  else
    perl -e 'alarm shift @ARGV; exec @ARGV' "$seconds" omp --profile "$PROFILE" "$@" 2>&1 || return 1
  fi
}
PROMPT_OK='Reply with exactly the single word PROBE-OK and nothing else.'
# trial <label> <model-id-expected> <omp args...>: print mode, JSON events; true when the reply and
# the requested model id both appear. The event shape is UNVERIFIED, so this is a substring match.
trial() {
  local want="$1" out="$WORK/trial.out"
  shift
  omp_p 120 "$@" --no-session --mode json -p "$PROMPT_OK" > "$out" 2>&1 || return 1
  grep -Fq PROBE-OK "$out" && grep -Fq -- "$want" "$out"
}

# 1. Which of the six ids does the catalog list.
IDS_JSON='{}'
if models="$(omp_p 30 models opencode-go --json)" && printf '%s' "$models" | jq -e '.models | type == "array"' >/dev/null 2>&1; then
  for id in $IDS; do
    if printf '%s' "$models" | jq -e --arg s "opencode-go/$id" 'any(.models[]; (.selector // (.provider + "/" + .id)) == $s)' >/dev/null; then
      IDS_JSON="$(printf '%s' "$IDS_JSON" | jq -c --arg i "$id" '.[$i] = true')"
    else
      IDS_JSON="$(printf '%s' "$IDS_JSON" | jq -c --arg i "$id" '.[$i] = false')"
    fi
  done
else
  for id in $IDS; do IDS_JSON="$(printf '%s' "$IDS_JSON" | jq -c --arg i "$id" '.[$i] = false')"; done
  note 'model catalog unreadable: not logged in, or opencode-go unknown to this omp'
fi
listed() { printf '%s' "$IDS_JSON" | jq -e --arg i "$1" '.[$i] == true' >/dev/null; }
FIRST=''
for id in $ARGON $QWEN $GLM $KIMI $FLASH $GLMFLASH; do
  if listed "$id"; then FIRST="$id"; break; fi
done

# 2. Launch mechanism, cheapest first: an overlay file, then --model, then the glen subcommand.
MECH=none
if [ -n "$FIRST" ]; then
  printf 'modelRoles:\n  default: opencode-go/%s\n' "$FIRST" > "$WORK/overlay.yml"
  if PI_CONFIG_FILES="$WORK/overlay.yml" trial "$FIRST"; then
    MECH=overlay
  elif trial "$FIRST" --model "opencode-go/$FIRST"; then
    MECH=startup_arg
  elif command -v glen >/dev/null 2>&1 && glen model --help >/dev/null 2>&1; then
    MECH=glen_model
    note 'glen model exists but was not exercised end to end'
  fi
fi

# 3. Does the key survive the engine's environment scrub, and does the stored login stand alone.
ENV_PASS=false LOGIN_OK=false
if [ -n "${OPENCODE_API_KEY:-}" ]; then
  envcheck_out="$WORK/envcheck.out"
  if /bin/bash "$ROOT/scripts/omp-engine.sh" envcheck --engine omp:opencode -- \
    /bin/sh -c 'test -n "${OPENCODE_API_KEY:-}"' > "$envcheck_out" 2>&1; then
    ENV_PASS=true
  elif grep -Fq 'launcher unavailable' "$envcheck_out"; then
    # The launcher is read from main in an installed .claude/ project; outside one, nothing was measured.
    ENV_PASS=null
    note 'env passthrough not measured: run the probe from an installed .claude/ project'
  fi
fi
DROP_KEY=1
if [ -n "$FIRST" ] && trial "$FIRST" --model "opencode-go/$FIRST"; then LOGIN_OK=true; fi
DROP_KEY=0

# 4. Cap signal: an authentic sample if given, else the usage shape only (keys, never values).
CAP=unknown
if [ -n "$CAP_SAMPLE" ] && [ -f "$CAP_SAMPLE" ] && grep -Eq "$CAP_RE" "$CAP_SAMPLE"; then CAP=immediate; fi
if usage="$(omp_p 30 usage --provider opencode-go --json)" && printf '%s' "$usage" | jq -e . >/dev/null 2>&1; then
  note "omp usage keys: $(printf '%s' "$usage" | jq -rc '[paths(scalars) | map(tostring) | join(".")] | unique | .[:20] | join(",")')"
else
  note 'omp usage did not return JSON for opencode-go'
fi

# 5. One trivial tool call per slot model (Gemini thought_signature risk on argon).
printf 'PROBE-%s\n' "$$" > "$WORK/probe.txt"
tool_call() {
  local id="$1" out="$WORK/tool.out"
  listed "$id" || return 1
  (cd "$WORK" && omp_p 180 --model "opencode-go/$id" --tools read --no-session -p 'Read the file probe.txt and reply with its exact contents.' > "$out" 2>&1) || return 1
  grep -Fq "PROBE-$$" "$out"
}
TOOLS_JSON='{}'
for pair in "argon:$ARGON" "qwen:$QWEN" "glm:$GLM" "flash:$FLASH"; do
  if tool_call "${pair#*:}"; then v=true; else v=false; fi
  TOOLS_JSON="$(printf '%s' "$TOOLS_JSON" | jq -c --arg k "${pair%%:*}" --argjson v "$v" '.[$k] = $v')"
done

# 6. --no-tools must stop the read: the token must not appear.
NO_TOOLS=false
if [ -n "$FIRST" ] && omp --help 2>/dev/null | grep -Fq -- --no-tools; then
  if (cd "$WORK" && omp_p 180 --model "opencode-go/$FIRST" --no-tools --no-session -p 'Read the file probe.txt and reply with its exact contents.' > "$WORK/nt.out" 2>&1) \
    && ! grep -Fq "PROBE-$$" "$WORK/nt.out"; then
    NO_TOOLS=true
  fi
fi

mkdir -p "$(dirname "$OUT")" "$(dirname "$EVIDENCE")"
jq -n --argjson ids "$IDS_JSON" --arg mech "$MECH" --argjson env "$ENV_PASS" --argjson login "$LOGIN_OK" \
  --arg cap "$CAP" --argjson tools "$TOOLS_JSON" --argjson nt "$NO_TOOLS" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ids:$ids,launch_mechanism:$mech,env_passthrough:$env,login_store_ok:$login,cap_signal:$cap,
    tools_ok:$tools,no_tools_flag:$nt,probed_at:$at}' > "$OUT"
{
  printf '# omp:opencode probe\n\nprofile %s, %s\n\n```json\n' "$PROFILE" "$(omp --version 2>/dev/null | head -n1)"
  cat "$OUT"
  printf '```\n\nNotes\n\n'
  cat "$NOTES"
  command -v glen >/dev/null 2>&1 && printf -- '- glen: %s\n' "$(glen --version 2>/dev/null | head -n1)"
} > "$EVIDENCE"
# Last line of defence: the key must not have reached either file.
if [ -n "${OPENCODE_API_KEY:-}" ] && grep -Fq -- "$OPENCODE_API_KEY" "$OUT" "$EVIDENCE"; then
  rm -f "$OUT" "$EVIDENCE"
  die 'the key appeared in the output; both files removed'
fi
say "wrote $OUT"
say "wrote $EVIDENCE"

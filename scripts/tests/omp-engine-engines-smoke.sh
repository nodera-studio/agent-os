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
assert_eq() { assert "$1" test "$2" = "$3"; }
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

printf '%s cases, %s failed\n' "$CASES" "$FAILURES"
[ "$FAILURES" -eq 0 ]

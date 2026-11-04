#!/bin/bash
# omp-profiles-smoke.sh — smoke test for .claude/omp/profiles.sh (Bash 3.2, no network).
#
# Usage: /bin/bash .claude/scripts/tests/omp-profiles-smoke.sh
# Cases: exact names known; unknown, empty, glob and prefix names rejected; engine, provider and login lookups;
# profile_for_engine. Exit 1 on any FAIL.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
OMP_DIR="$HERE/../../omp"
# shellcheck source=../../omp/profiles.sh
. "$OMP_DIR/profiles.sh"
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
pass_if() { if "${@:2}"; then ok "$1"; else fail "$1"; fi; }
fail_if() { if "${@:2}"; then fail "$1"; else ok "$1"; fi; }

pass_if 'codex profile known' profile_known glen-harness-codex
pass_if 'opencode profile known' profile_known glen-harness-opencode
pass_if 'legacy profile known' profile_known glen-harness
fail_if 'unknown name rejected' profile_known glen-harness-probe
fail_if 'glen-harness-evil rejected' profile_known glen-harness-evil
fail_if 'glob rejected' profile_known 'glen-harness-*'
fail_if 'star rejected' profile_known '*'
fail_if 'empty rejected' profile_known ''
fail_if 'prefix of a known name rejected' profile_known glen-harness-code
fail_if 'known name plus suffix rejected' profile_known glen-harness-codex2

[ "$(profile_provider glen-harness-codex)" = openai-codex ] && ok 'codex provider' || fail 'codex provider'
[ "$(profile_provider glen-harness-opencode)" = opencode-go ] && ok 'opencode provider' || fail 'opencode provider'
[ "$(profile_engine glen-harness-opencode)" = omp:opencode ] && ok 'opencode engine' || fail 'opencode engine'
[ "$(profile_login_cmd glen-harness-codex)" = 'login openai-codex' ] && ok 'codex login hint' || fail 'codex login hint'
[ "$(profile_for_engine omp:codex)" = glen-harness-codex ] && ok 'profile_for_engine omp:codex' || fail 'profile_for_engine omp:codex'
[ "$(profile_for_engine omp:opencode)" = glen-harness-opencode ] && ok 'profile_for_engine omp:opencode' || fail 'profile_for_engine omp:opencode'
fail_if 'profile_for_engine unknown' profile_for_engine omp:zen
fail_if 'the new profiles are not legacy' profile_legacy glen-harness-codex
pass_if 'the cursor profile is legacy' profile_legacy glen-harness

[ "$FAILS" -eq 0 ]

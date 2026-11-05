# shellcheck shell=bash disable=SC2034 # Sourced; OMP_PROFILES is read by the functions below.
# The one list of omp profiles this harness may use. Sourced by omp-engine.sh, omp-profile-setup.sh
# and hooks/steer-bash.sh. The sandbox launchers run from a cache outside the checkout and cannot
# source it, so each carries the same names inline; omp-profiles-smoke.sh checks that they agree.
# Row: name|engine|provider|login subcommand. Exactly these two profiles exist; there is no default profile.
# Matching is exact on the name, never a glob: a prefix pattern would admit any glen-harness-* name.
# Bash 3.2: indexed arrays only.
OMP_PROFILES=(
  'glen-harness-codex|omp:codex|openai-codex|login openai-codex'
  'glen-harness-opencode|omp:opencode|opencode-go|login opencode-go'
)

# profile_row <name>: the whole row, or status 1.
profile_row() {
  local row
  for row in "${OMP_PROFILES[@]}"; do
    case "$row" in "$1|"*) printf '%s\n' "$row"; return 0 ;; esac
  done
  return 1
}
# profile_field <name> <1-based field>
profile_field() {
  local row f1 f2 f3 f4
  row="$(profile_row "$1")" || return 1
  IFS='|' read -r f1 f2 f3 f4 <<EOF
$row
EOF
  case "$2" in 1) printf '%s\n' "$f1" ;; 2) printf '%s\n' "$f2" ;; 3) printf '%s\n' "$f3" ;; 4) printf '%s\n' "$f4" ;; *) return 1 ;; esac
}
profile_known() { profile_row "$1" >/dev/null; }
profile_engine() { profile_field "$1" 2; }
profile_provider() { profile_field "$1" 3; }
profile_login_cmd() { profile_field "$1" 4; }
# profile_for_engine <engine>: the profile that serves it.
profile_for_engine() {
  local row
  for row in "${OMP_PROFILES[@]}"; do
    case "$row" in *"|$1|"*) printf '%s\n' "${row%%|*}"; return 0 ;; esac
  done
  return 1
}
profile_names() {
  local row
  for row in "${OMP_PROFILES[@]}"; do printf '%s\n' "${row%%|*}"; done
}

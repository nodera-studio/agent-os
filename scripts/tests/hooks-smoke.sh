#!/usr/bin/env bash
# hooks-smoke.sh — the hook fixes of wave 2b: steer-bash cat rule and scratch path, reinject-invariants,
# prettier-on-edit and block-legacy-engines. Feeds hook JSON on stdin and checks the decision or output.
# Needs jq (the hooks fail open without it, so a missing jq is a failure here, not a pass).
# Bash 3.2, no network.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
HOOKS="$ROOT/hooks"
command -v jq >/dev/null 2>&1 || { echo "FAIL jq is required" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hooks-smoke.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
CASES=0 FAILURES=0

check() { # check <label> <want> <got>
  CASES=$((CASES + 1))
  if [ "$2" = "$3" ]; then
    printf 'PASS %s\n' "$1"
  else
    printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

bash_decision() { # bash_decision <hook> <command>: allow or deny (the hook's PreToolUse decision)
  local out got
  out=$(jq -n --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}' | /bin/bash "$HOOKS/$1" 2>/dev/null) || true
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null) || true
  printf '%s' "${got:-allow}"
}
steer() { check "steer-bash $1: $2" "$1" "$(bash_decision steer-bash.sh "$2")"; }

# --- 11a: steer-bash reads (AC-040) and the scratch helper path ---
steer allow 'cat README.md'
steer allow 'head -20 docs/plan.json'
steer allow 'tail -n 5 config.yaml'
steer allow 'cat settings.toml'
steer allow 'cat notes.mdx'
steer deny  'cat src/index.ts'
steer deny  'head -5 app/page.tsx'
steer deny  'tail -n 3 lib/util.js'
steer deny  'cat styles/main.scss'
steer deny  'cat db/schema.sql'
steer allow 'cat <<EOF > out.ts'
steer deny  'cat .env'
steer deny  'head .env.local'
steer allow 'cat .env.example'
reason=$(jq -n --arg c "rm -rf \"\$TMPDIR/proj-x\"" '{tool_name:"Bash",tool_input:{command:$c}}' \
  | HARNESS_SCRATCH_PREFIX=proj- /bin/bash "$HOOKS/steer-bash.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason" in *'bash .claude/scripts/clean-scratch.sh '*) check 'scratch advice names the default helper path' ok ok ;; *) check 'scratch advice names the default helper path' ok "$reason" ;; esac
reason=$(jq -n --arg c "rm -rf \"\$TMPDIR/proj-x\"" '{tool_name:"Bash",tool_input:{command:$c}}' \
  | HARNESS_SCRATCH_PREFIX=proj- HARNESS_CLEAN_SCRATCH=tools/clean.sh /bin/bash "$HOOKS/steer-bash.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason" in *'bash tools/clean.sh '*) check 'scratch helper path is configurable' ok ok ;; *) check 'scratch helper path is configurable' ok "$reason" ;; esac

# --- 11b: reinject-invariants prints nothing while the placeholder remains (AC-041) ---
reinject() { /bin/bash "$1/hooks/reinject-invariants.sh" </dev/null 2>/dev/null || true; }
check 'the shipped placeholder payload prints nothing' '' "$(reinject "$ROOT")"
RI="$WORK/reinject"
mkdir -p "$RI/hooks" "$RI/rules"
cp "$HOOKS/reinject-invariants.sh" "$RI/hooks/"
check 'no payload file prints nothing' '' "$(reinject "$RI")"
printf -- '---\npaths:\n  - "x"\n---\n1. Never bypass the repository layer.\n' >"$RI/rules/invariants.md"
check 'a real payload prints, frontmatter stripped' '1. Never bypass the repository layer.' "$(reinject "$RI")"
printf -- '1. Real rule.\n2. [Add your project'"'"'s second invariant here]\n' >"$RI/rules/invariants.md"
check 'any remaining placeholder keeps it silent' '' "$(reinject "$RI")"
mkdir -p "$WORK/link/hooks"
printf -- '1. Via a symlink.\n' >"$RI/rules/invariants.md"
ln -s "$RI/hooks/reinject-invariants.sh" "$WORK/link/hooks/reinject-invariants.sh"
check 'a symlinked hook finds the payload beside its target' '1. Via a symlink.' "$(/bin/bash "$WORK/link/hooks/reinject-invariants.sh" </dev/null)"
check 'settings.json runs it on resume|compact only' 'resume|compact' \
  "$(jq -r '.hooks.SessionStart[] | select(any(.hooks[]; .command | endswith("reinject-invariants.sh"))) | .matcher' "$ROOT/settings.json")"
check 'the unmatched SessionStart group no longer reinjects' 0 \
  "$(jq '[.hooks.SessionStart[] | select(.matcher == null) | .hooks[] | select(.command | endswith("reinject-invariants.sh"))] | length' "$ROOT/settings.json")"
check 'the payload file is not an always-on rule (it carries paths:)' 1 "$(head -n 6 "$ROOT/rules/invariants.md" | grep -c '^paths:')"

printf '%d cases, %d failures\n' "$CASES" "$FAILURES"
[ "$FAILURES" -eq 0 ]

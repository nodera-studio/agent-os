#!/usr/bin/env bash
# hooks-smoke.sh — the hook fixes of wave 2b: steer-bash cat rule and scratch path, reinject-invariants
# (with the orchestrator-mode notice), post-edit-lint (prettier and shellcheck) and block-legacy-engines. Feeds hook JSON on stdin and checks the decision or output.
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
# the hook gates the payload on the SessionStart source itself, so settings.json wires one unmatched group
src() { jq -n --arg s "$1" '{hook_event_name:"SessionStart",source:$s}' | /bin/bash "$RI/hooks/reinject-invariants.sh" 2>/dev/null || true; }
check 'SessionStart source resume prints the payload' '1. Via a symlink.' "$(src resume)"
check 'SessionStart source compact prints the payload' '1. Via a symlink.' "$(src compact)"
check 'SessionStart source startup prints no payload' '' "$(src startup)"
check 'SessionStart source clear prints no payload' '' "$(src clear)"
check 'PreCompact (no source) prints the payload' '1. Via a symlink.' "$(jq -n '{hook_event_name:"PreCompact"}' | /bin/bash "$RI/hooks/reinject-invariants.sh" 2>/dev/null || true)"
# the orchestrator-mode notice prints on every session start, in the project root
NOTICE='Orchestrator mode is ON (dispatch-only — see .claude/agents/orchestrator/orchestrator-mode.md). Run /orchestrate off to disable.'
mkdir -p "$WORK/om/.claude"
om() { (cd "$WORK/om" && jq -n --arg s "$1" '{hook_event_name:"SessionStart",source:$s}' | /bin/bash "$RI/hooks/reinject-invariants.sh" 2>/dev/null) || true; }
check 'no .orchestrator-mode marker: no notice' '1. Via a symlink.' "$(om resume)"
: >"$WORK/om/.claude/.orchestrator-mode"
check 'the marker prints the notice on startup' "$NOTICE" "$(om startup)"
check 'the marker prints the notice, then the payload, on resume' "$NOTICE
1. Via a symlink." "$(om resume)"
check 'settings.json runs it from one unmatched SessionStart group' 1 \
  "$(jq '[.hooks.SessionStart[] | select(.matcher == null) | .hooks[] | select(.command | endswith("reinject-invariants.sh"))] | length' "$ROOT/settings.json")"
check 'settings.json also runs it on PreCompact' 1 \
  "$(jq '[.hooks.PreCompact[] | .hooks[] | select(.command | endswith("reinject-invariants.sh"))] | length' "$ROOT/settings.json")"
missing=0
for c in $(jq -r '[.hooks[][] | .hooks[] | .command] | unique[]' "$ROOT/settings.json"); do [ -f "$ROOT/${c#.claude/}" ] || missing=$((missing + 1)); done
check 'every hook command in settings.json names an existing file' 0 "$missing"
check 'the payload file is not an always-on rule (it carries paths:)' 1 "$(head -n 6 "$ROOT/rules/invariants.md" | grep -c '^paths:')"

# --- 11c: post-edit-lint runs prettier only when configured and installed, and reports through additionalContext (AC-042) ---
prettier_out() { # prettier_out <file>: the hook's stdout for an Edit of <file>
  jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}' | /bin/bash "$HOOKS/post-edit-lint.sh" 2>/dev/null || true
}
mkpkg() { # mkpkg <dir> <package.json>
  mkdir -p "$1/src"
  printf '%s\n' "$2" >"$1/package.json"
  printf 'const a   =  1\n' >"$1/src/a.ts"
}
# a stub prettier that records its argv and either formats (rewrites the file) or fails
stub_prettier() { # stub_prettier <dir> ok|fail
  mkdir -p "$1/node_modules/.bin"
  if [ "$2" = ok ]; then
    printf '#!/bin/sh\necho "$@" >"%s/prettier-argv"\nfor last; do :; done\nprintf "const a = 1;\\n" >"$last"\n' "$WORK" >"$1/node_modules/.bin/prettier"
  else
    printf '#!/bin/sh\necho "SyntaxError: boom" >&2\nexit 2\n' >"$1/node_modules/.bin/prettier"
  fi
  chmod +x "$1/node_modules/.bin/prettier"
}
P1="$WORK/p-noconfig"; mkpkg "$P1" '{"name":"x"}'; stub_prettier "$P1" ok
check 'no prettier config: silent, file untouched' 'const a   =  1' "$(prettier_out "$P1/src/a.ts" >/dev/null; cat "$P1/src/a.ts")"
P2="$WORK/p-notinstalled"; mkpkg "$P2" '{"name":"x","devDependencies":{"prettier":"^3"}}'
check 'configured but not installed: silent' '' "$(prettier_out "$P2/src/a.ts")"
P3="$WORK/p-ok"; mkpkg "$P3" '{"name":"x","devDependencies":{"prettier":"^3"}}'; stub_prettier "$P3" ok
check 'configured and installed: no output on success' '' "$(prettier_out "$P3/src/a.ts")"
check 'and the file is formatted by the local binary' 'const a = 1;' "$(cat "$P3/src/a.ts")"
P4="$WORK/p-rc"; mkpkg "$P4" '{"name":"x"}'; : >"$P4/.prettierrc"; stub_prettier "$P4" ok
prettier_out "$P4/src/a.ts" >/dev/null
check 'a config file alone also enables it' 'const a = 1;' "$(cat "$P4/src/a.ts")"
P5="$WORK/p-fail"; mkpkg "$P5" '{"name":"x","prettier":{}}'; stub_prettier "$P5" fail
out=$(prettier_out "$P5/src/a.ts")
check 'a failure goes through additionalContext' PostToolUse "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"
case "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" in *'SyntaxError: boom'*) check 'the context carries prettier output' ok ok ;; *) check 'the context carries prettier output' ok "$out" ;; esac
check 'a failure never exits non-zero' 0 "$(jq -n --arg f "$P5/src/a.ts" '{tool_input:{file_path:$f}}' | /bin/bash "$HOOKS/post-edit-lint.sh" >/dev/null 2>&1; echo $?)"
mkdir -p "$WORK/nopkg"; printf 'x\n' >"$WORK/nopkg/a.ts"
check 'no package.json above the file: silent' '' "$(prettier_out "$WORK/nopkg/a.ts")"
printf 'x\n' >"$P3/src/readme.md"
check 'a non-code extension is ignored' '' "$(prettier_out "$P3/src/readme.md")"
if grep -q 'pnpm\|rebuild-shared' "$HOOKS/post-edit-lint.sh"; then check 'no pnpm assumption or dangling comment' clean dirty; else check 'no pnpm assumption or dangling comment' clean clean; fi

# post-edit-lint also lints shell scripts (shellcheck -S warning -f gcc, through additionalContext), and the old hooks are gone
lint_out() { jq -n --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f}}' | /bin/bash "$HOOKS/post-edit-lint.sh" 2>/dev/null || true; }
if command -v shellcheck >/dev/null 2>&1; then
  printf '#!/bin/bash\nx=1\n' >"$WORK/bad.sh"
  out=$(lint_out "$WORK/bad.sh")
  check 'a shell script with a warning goes through additionalContext' PostToolUse "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"
  case "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" in *'bad.sh'*'SC2034'*) check 'the context carries the gcc-format finding' ok ok ;; *) check 'the context carries the gcc-format finding' ok "$out" ;; esac
  printf '#!/bin/bash\necho "$1"\n' >"$WORK/good.sh"
  check 'a clean shell script is silent' '' "$(lint_out "$WORK/good.sh")"
  printf '#!/bin/bash\necho $1\n' >"$WORK/info.sh"
  check 'a sh file that is clean at warning severity is silent' '' "$(lint_out "$WORK/info.sh")"
fi
check 'a missing file is silent' '' "$(lint_out "$WORK/nope.sh")"
check 'an unrelated extension is silent' '' "$(lint_out "$P3/src/readme.md")"
check 'a shell extension never reaches prettier' '' "$(printf '#!/bin/bash\n:\n' >"$P3/src/x.sh"; lint_out "$P3/src/x.sh")"
check 'settings.json wires one PostToolUse lint hook' 1 "$(jq '[.hooks.PostToolUse[] | .hooks[] | select(.command | endswith("post-edit-lint.sh"))] | length' "$ROOT/settings.json")"

# --- 11d: block-legacy-engines segments on the command word (AC-032, AC-033) ---
legacy() { check "legacy-engines $1: $2" "$1" "$(bash_decision block-legacy-engines.sh "$2")"; }
# codex exec as a command word
legacy deny  'codex exec "fix the bug"'
legacy deny  'cd /repo && codex exec -m x go'
legacy deny  'echo hi | codex exec -'
legacy deny  'timeout 30 codex exec x'
legacy deny  'env FOO=1 /usr/local/bin/codex exec x'
legacy deny  "sh -c 'codex exec x'"
legacy deny  'bash -lc "cd x; codex exec y"'
legacy deny  'x=$(codex exec y)'
legacy deny  '(codex exec y)'
legacy deny  'FOO=1 codex exec y'
legacy deny  'echo ok; codex exec y'
legacy deny  'git log | xargs codex exec'
# bare omp as a command word
legacy deny  'omp -p hello'
legacy deny  'omp models'
legacy deny  'HOME="$T" omp models'
legacy deny  'env OMP_PROFILE=glen-harness-codex omp models'
legacy deny  'nice -n 5 /usr/local/bin/omp x'
legacy deny  'bash -c "omp models"'
legacy deny  'ls && omp'
# the same words as data: commit messages, echo, heredocs, quotes, comments, searches
legacy allow 'git commit -m "docs: ban codex exec and bare omp"'
legacy allow "git commit -m 'codex exec; omp x'"
legacy allow 'echo "run omp models; codex exec is gone"'
legacy allow "printf '%s\n' 'codex exec x'"
legacy allow 'rg "codex exec" docs'
legacy allow 'grep -rn "omp " .'
legacy allow '# codex exec x'
legacy allow 'ls # omp models'
legacy allow "git commit -m \"\$(cat <<'EOF'
docs: mention codex exec
omp models is denied
EOF
)\""
legacy allow "cat <<'EOF' > notes.md
codex exec foo
omp bar
EOF
echo done"
legacy allow 'cat <<-EOF
	omp x
	EOF'
legacy deny "cat <<'EOF' > notes.md
data only
EOF
omp models"
# allowed forms of the real tools
legacy allow 'codex --version'
legacy allow 'codex login'
legacy allow 'node ~/.claude/plugins/codex/scripts/codex-companion.mjs task "x"'
legacy allow 'bash .claude/scripts/omp-engine.sh review --engine omp:codex --role review --uncommitted --out /tmp/o'
legacy allow 'bash scripts/omp-engine.sh probe'
legacy allow 'omp --version'
legacy allow 'omp --help'
legacy allow 'command -v omp'
legacy allow 'which omp'
legacy allow 'ls /usr/local/bin'
skill_decision() {
  local out got
  out=$(jq -n --arg s "$1" '{tool_name:"Skill",tool_input:{skill:$s}}' | /bin/bash "$HOOKS/block-legacy-engines.sh" 2>/dev/null) || true
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null) || true
  printf '%s' "${got:-allow}"
}
check 'legacy-engines skill: skill-codex:codex denied' deny "$(skill_decision skill-codex:codex)"
check 'legacy-engines skill: another skill allowed' allow "$(skill_decision omp)"
check 'non-Bash tools are ignored' '' "$(jq -n '{tool_name:"Edit",tool_input:{file_path:"codex exec"}}' | /bin/bash "$HOOKS/block-legacy-engines.sh")"
check 'settings.json wires it for Bash' 1 "$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | endswith("block-legacy-engines.sh"))] | length' "$ROOT/settings.json")"
check 'settings.json wires it for Skill' 1 "$(jq '[.hooks.PreToolUse[] | select(.matcher == "Skill") | .hooks[] | select(.command | endswith("block-legacy-engines.sh"))] | length' "$ROOT/settings.json")"
check 'block-old-codex.sh stays wired until the pack move' 2 "$(jq '[.hooks.PreToolUse[] | .hooks[] | select(.command | endswith("block-old-codex.sh"))] | length' "$ROOT/settings.json")"

check 'hook advice names the plugin tool names, not the bare mcp__memory__/mcp__secrets__ ones' 0 \
  "$(grep -c 'mcp__memory__\|mcp__secrets__' "$HOOKS"/*.sh | awk -F: '{s += $2} END {print s + 0}')"

printf '%d cases, %d failures\n' "$CASES" "$FAILURES"
[ "$FAILURES" -eq 0 ]

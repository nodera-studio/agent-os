#!/usr/bin/env bash
# PreToolUse(Bash) — steer off native shell tools onto Claude's structured tools.
# Reads the hook JSON on stdin; emits a deny JSON on exit 0 (block-and-instruct — the
# updatedInput rewrite is documented but unreliable, so we deny + name the replacement).
#
# Scope (deliberately narrow — over-blocking traps the agent in retry loops):
#   - `sed -i` editing a file        -> Edit tool / LSP rename
#   - `cat`/`head`/`tail` of a CODE file (ts/js/css/sql; not heredocs, docs, config or logs) -> Read tool
#   - shell reads of `.env`/secret files (not `.env.example`)     -> secrets MCP
#   - `curl`/`wget` to an EXTERNAL url -> Exa MCP (web) / a service SDK-CLI (APIs).
#     Loopback stays allowed (local API, MCP servers, health checks). Every URL in the
#     whole command must be on the allow-list.
#   - recursive `rm` of this project's scratch (<prefix>* under $TMPDIR, /tmp or
#     /var/folders) -> scripts/clean-scratch.sh, which refuses anything still in use.
#     <prefix> is HARNESS_SCRATCH_PREFIX, else the main checkout's directory name plus `-`;
#     the helper's path in the advice is HARNESS_CLEAN_SCRATCH, else .claude/scripts/clean-scratch.sh.
#   - `omp` with a profile not in omp/profiles.sh (`--profile`, OMP_PROFILE, PI_PROFILE), and
#     `mkdir`/`cp`/`mv`/`rsync`/`ln` into another ~/.omp/profiles/<name> -> HOME="$(mktemp -d)"
# Does NOT touch grep/rg (agentic search is good in-loop — routed via CLAUDE.md)
# or codex (block-legacy-engines.sh). Fails open on any error. Project-specific
# steering (e.g. a dev-tool wrapper hook) can be layered in separately — see
# hooks/README.md ("Custom hooks for your project").
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$CMD" ] && exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
  exit 0
}

# omp probes: omp joins PI_CONFIG_DIR onto $HOME, and a named profile ignores
# PI_CODING_AGENT_DIR, so the only isolation is a throwaway HOME or the approved profile.
# The allowlist is exact names from omp/profiles.sh next to this hook. If that file is missing or
# does not load, a hardcoded copy of the names applies: the guard never falls open.
OMP_PROFILES_OK=0
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _dir=$(cd "$(dirname "$_self")" && pwd -P)
  _self=$(readlink "$_self")
  case "$_self" in /*) ;; *) _self="$_dir/$_self" ;; esac
done
_reg="$(cd "$(dirname "$_self")/.." 2>/dev/null && pwd -P)/omp/profiles.sh"
# shellcheck source=../omp/profiles.sh
if [ -f "$_reg" ] && . "$_reg" >/dev/null 2>&1 && type profile_known >/dev/null 2>&1; then
  OMP_PROFILES_OK=1
fi
# omp_profile_ok NAME: NAME is an approved profile (exact match, never a prefix or glob).
omp_profile_ok() {
  if [ "$OMP_PROFILES_OK" = 1 ]; then profile_known "$1"; return; fi
  case "$1" in glen-harness-codex | glen-harness-opencode | glen-harness) return 0 ;; esac
  return 1
}
# shellcheck disable=SC2016 # the $(mktemp -d) and $HOME are literal advice text
OMP_PROFILE_REASON='omp probes use a throwaway home: HOME="$(mktemp -d)" omp … (omp joins PI_CONFIG_DIR onto $HOME, so an absolute PI_CONFIG_DIR still writes under ~), or an approved profile (omp/profiles.sh). Never create another ~/.omp/profiles/<name> (harness rule).'
# a profile name with surrounding quotes (and a subshell's closing paren) removed
unquote() { printf '%s' "$1" | tr -d "\"')"; }
REAL_HOME="${HOME:-}"
[ -n "$REAL_HOME" ] || REAL_HOME=/nonexistent-home
# the command word of a segment behind `(` and the wrappers env (VAR=v, -i, -u N), timeout
# (-s S, -k K, the duration), nice (-n N), command, nohup, exec, time, builtin
cmd_word() {
  printf '%s' "$1" | awk '{
    i = 1
    while (i <= NF) {
      w = $i; sub(/^\(+/, "", w)
      if (w == "" || w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
      if (w == "env") { i++; while (i <= NF && $i ~ /^-/) { if ($i == "-u") i++; i++ }; continue }
      if (w == "timeout") { i++; while (i <= NF && $i ~ /^-/) { if ($i == "-s" || $i == "-k") i++; i++ }; i++; continue }
      if (w == "nice") { i++; if ($i == "-n") i += 2; else if ($i ~ /^-/) i++; continue }
      if (w == "command" || w == "nohup" || w == "exec" || w == "time" || w == "builtin") { i++; while (i <= NF && $i ~ /^-/) i++; continue }
      print w; exit
    }
  }'
}
# omp_profile_check SEG: deny a --profile in SEG, or OMP_PROFILE= / PI_PROFILE= anywhere in the
# command (an `export` earlier in the chain counts), that is not an approved profile. Empty = default.
omp_profile_check() {
  local names name
  names=$( { printf '%s' "$1" | grep -oE -- '--profile[= ]+[^[:space:]]+' | sed -E 's/^--profile[= ]+//'
             printf '%s' "$CMD" | grep -oE '(^|[^A-Za-z0-9_])(OMP|PI)_PROFILE=[^[:space:];&|]*' | sed -E 's/^.*_PROFILE=//'; } 2>/dev/null)
  while IFS= read -r name; do
    name=$(unquote "$name")
    if [ -n "$name" ] && ! omp_profile_ok "$name"; then
      deny "$OMP_PROFILE_REASON"
    fi
  done <<< "$names"
}

# scratch_prefix: this project's scratch prefix (see clean-scratch.sh); empty if unknown.
scratch_prefix() {
  if [ -n "${HARNESS_SCRATCH_PREFIX:-}" ]; then printf '%s' "$HARNESS_SCRATCH_PREFIX"; return; fi
  local dir common
  dir=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  dir=${dir:-${CLAUDE_PROJECT_DIR:-$PWD}}
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  common=$(cd "$common/.." 2>/dev/null && pwd -P) || return 0
  printf '%s-' "${common##*/}"
}

# split on pipes and ; & && || so each segment is inspected on its own
# (|| [ -n "$seg" ] handles the final newline-less segment; tr is BSD/GNU-portable)
while IFS= read -r seg || [ -n "$seg" ]; do
  [ -z "$seg" ] && continue
  base=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^ ]* +)+//' | awk '{print $1}')
  base=$(basename "$base" 2>/dev/null)

  # omp behind a wrapper (timeout, env, a subshell), or inside `sh|bash|zsh -c '…'`
  inner=$(basename "$(cmd_word "$seg")" 2>/dev/null)
  if [ "$inner" = omp ] || { case "$inner" in sh|bash|zsh|dash) true ;; *) false ;; esac \
       && printf '%s' "$seg" | grep -qE "(^|[[:space:](\"'/])omp([[:space:]\"']|\$)"; }; then
    omp_profile_check "$seg"
  fi

  # shell reads of real secret files (not .env.example) -> secrets MCP
  if printf '%s' "$seg" | grep -qE '\.env(\.[a-z._-]+)?' \
     && ! printf '%s' "$seg" | grep -qE '\.env(\.[a-z._-]*)?\.example' \
     && printf '%s' "$base" | grep -qE '^(cat|less|more|head|tail|grep|rg|bat|xxd|od|strings|awk|sed)$'; then
    deny "Don't read .env / secret files from the shell. Use the secrets MCP (mcp__plugin_mnemosyne_secrets__*) — secrets must never enter context. (.env.example templates are fine via the Read tool.)"
  fi

  case "$base" in
    sed)
      if printf '%s' "$seg" | grep -qE '(^|[[:space:]])(-i|--in-place)'; then
        deny "Don't edit files with 'sed -i'. Use the Edit tool (deterministic + reviewable), or the LSP rename for symbol renames."
      fi
      ;;
    cat|head|tail)
      # allow heredocs (cat <<EOF) and non-code reads (docs, config, logs); block reads of code files
      if ! printf '%s' "$seg" | grep -qE '<<' \
         && printf '%s' "$seg" | grep -qE '\.(ts|tsx|js|jsx|mjs|cjs|css|scss|sql)([[:space:]]|$|"|'"'"')'; then
        deny "Don't read files with $base. Use the Read tool — cacheable, structured, supports offset/limit."
      fi
      ;;
    curl|wget)
      # Service-specific redirects fire FIRST (more useful reason than the generic deny below).
      # These name the ONE replacement tool — no routing index duplicated in the hook.
      if printf '%s' "$seg" | grep -qiE 'https?://([a-z0-9.-]+\.)?cloudflare\.com([:/ ]|$|"|'"'"')'; then
        deny "Don't curl Cloudflare's API — use the wrangler CLI (deploy / R2 / D1 writes, headless) or the Cloudflare MCP (read-only account queries). See the cloudflare:wrangler skill and rules/object-lock.md."
      fi
      if printf '%s' "$seg" | grep -qiE 'https?://([a-z0-9.-]+\.)?sentry\.io([:/ ]|$|"|'"'"')'; then
        deny "Don't curl Sentry's API — use sentry-cli (releases / sourcemaps) or the Sentry MCP (issue lookup / Seer)."
      fi
      if printf '%s' "$seg" | grep -qiE 'https?://([a-z0-9.-]+\.)?linear\.app([:/ ]|$|"|'"'"')'; then
        deny "Don't curl Linear's API — use the Linear connector (mcp__*Linear* tools)."
      fi
      # Loopback stays allowed. External http(s) fetches are denied: route web
      # CONTENT to the Exa MCP, and known APIs to their SDK/CLI — WebFetch is
      # off by design, and ad-hoc scraping bypasses the stack. Extend
      # ALLOW_HOSTS for any new endpoint you genuinely need (the deliberate
      # "deny-but-whitelist" knob). curl/wget with no http url (--version,
      # file://, pipes) is fine.
      # Add your own trusted remote hosts here if needed (e.g. your own infra
      # boxes, self-hosted services, the project's own deployed site for live
      # status/header checks) — only loopback ships by default.
      ALLOW_HOSTS='localhost|127\.0\.0\.1|0\.0\.0\.0|::1'
      # Every URL in the WHOLE command must be on the allow-list: one allowed URL must
      # not smuggle an external one through, and the segment splitter is not
      # quote-aware, so scan $CMD rather than $seg. Only a numeric port may follow the
      # host (`host:x@evil` is userinfo, not a port).
      bad_url=$(printf '%s' "$CMD" | grep -oiE "https?://[^[:space:]\"'\`]*" \
        | grep -viE "^https?://\[?($ALLOW_HOSTS)\]?(:[0-9]*)?([/?#]|\$)" | head -n 1)
      if [ -n "$bad_url" ]; then
        deny "Don't fetch external URLs with $base — WebFetch is off by design. For web content use the Exa MCP (web_search_exa / advanced search + crawl); for a known service use its SDK/CLI. Loopback is allowed — add a host to ALLOW_HOSTS in hooks/steer-bash.sh for anything else you genuinely need."
      fi
      ;;
    find)
      # File-SEARCH forms (-name/-path/-type f) -> rg --files / codebase MCP. OPERATIONAL forms
      # (-exec/-delete/-mtime/-newer/-size/-empty) are real work and stay allowed.
      if printf '%s' "$seg" | grep -qE '(^|[[:space:]])-(i?name|i?path|type)([[:space:]]|$)' \
         && ! printf '%s' "$seg" | grep -qE '(^|[[:space:]])-(exec(dir)?|delete|[mc]time|newer|size|empty)([[:space:]]|$)'; then
        deny "Don't search for files with 'find'. Use 'rg --files | rg <pattern>' (fast, respects .gitignore) for literal file lookups, or the codebase MCP for conceptual 'where does X live'. Operational find (-exec / -delete / -mtime …) is fine."
      fi
      ;;
    mkdir|cp|mv|rsync|ln)
      # only the real home's profiles (~, $HOME, ${HOME} or its literal path); a throwaway
      # HOME such as "$T/.omp/profiles/x" is what the advice asks for, so it stays allowed
      # shellcheck disable=SC2016 # $HOME / ${HOME} are matched literally in the command text
      names=$(printf '%s' "${seg//"$REAL_HOME"/\~}" \
        | grep -oE '(~|\$HOME|\$\{HOME\})"?/\.omp/profiles/[^/[:space:]]+' | sed -E 's#^.*\.omp/profiles/##' 2>/dev/null)
      while IFS= read -r name; do
        name=$(unquote "$name")
        if [ -n "$name" ] && ! omp_profile_ok "$name"; then
          deny "$OMP_PROFILE_REASON"
        fi
      done <<< "$names"
      ;;
    rm)
      # recursive deletes of this project's scratch in the temp dirs -> the helper, which
      # refuses anything a worktree or a process still uses
      if printf '%s' "$seg" | grep -qE '(^|[[:space:]])(-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$)'; then
        prefix=$(scratch_prefix)
        # the prefix as a literal ERE (escape the metacharacters a directory name may hold)
        prefix_re=$(printf '%s' "$prefix" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
        # shellcheck disable=SC2016 # $TMPDIR / ${TMPDIR} are matched literally in the command text
        if [ -n "$prefix" ] \
           && printf '%s' "$seg" | grep -qE '(\$TMPDIR|\$\{TMPDIR[^}]*\}|/tmp/|/private/tmp/|/var/folders/|/private/var/folders/)[^[:space:]]*'"$prefix_re"; then
          deny "Delete scratch with the helper: bash ${HARNESS_CLEAN_SCRATCH:-.claude/scripts/clean-scratch.sh} [--dry-run] '${prefix}<name or glob>' (it refuses anything a worktree or process still uses). rm -rf stays denied."
        fi
      fi
      ;;
  esac
done < <(printf '%s\n' "$CMD" | tr '|;&' '\n')
exit 0

#!/usr/bin/env bash
# PreToolUse(Bash|Skill) — block the legacy engine paths: `codex exec` and a bare `omp`.
#
# Codex runs only as a read-only omp engine now, and omp is reached only through
# scripts/omp-engine.sh (which pins the profile, the sandbox launcher and the model). The check
# works on the COMMAND WORD of each command, not on text anywhere in the line, so the same words
# in a commit message, an echo, a heredoc body, a quoted argument or a comment never trip it:
#   - quotes, backslashes, comments and heredoc bodies are removed before words are read
#   - the command line is split at ; & && | || newlines and ( ) into separate commands
#   - $( ), backticks and sh|bash|zsh -c '…' / eval payloads are checked as commands too
#   - env, command, nohup, exec, time, nice, timeout and sudo prefixes are looked through
# Denied: `codex … exec` (any path to codex) and `omp …`. Allowed: `omp --version|--help` alone,
# `command -v omp`, everything else that merely mentions the words, and any command that goes
# through scripts/omp-engine.sh (its command word is the script, not omp).
# Block-and-instruct on exit 0, like steer-bash.sh. Fails open without jq. It is the only engine guard in
# core; the codex pack adds a plugin-transport guard of its own.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
  exit 0
}
USE_ENGINE='Codex is a read-only omp engine now: bash .claude/scripts/omp-engine.sh review|debug|ask --engine omp:codex --role <role> … (see the omp skill). Claude stays the only writer.'

if [ "$TOOL" = Skill ]; then
  skill=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null)
  case "$skill" in
    skill-codex:codex | plugin:skill-codex:codex) deny "The skill-codex wrapper is the dropped legacy path. $USE_ENGINE" ;;
  esac
  exit 0
fi
[ "$TOOL" = Bash ] || exit 0
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
# cheap pre-filter: no mention of either word, nothing to parse
case "$CMD" in *codex* | *omp*) ;; *) exit 0 ;; esac

# The awk program prints "codex-exec" or "omp" for the first offending command, else nothing.
# "\047" is a single quote (this program sits inside shell single quotes).
FOUND=$(printf '%s' "$CMD" | awk '
function matchparen(s, p,    d, c, n) {
  n = length(s); d = 1
  while (p <= n) {
    c = substr(s, p, 1)
    if (c == "(") d++
    else if (c == ")") { d--; if (d == 0) return p }
    p++
  }
  return n + 1
}
function analyze(s,    wd, n, i, c, nx, st, word, have, nw, skipnext, hdn, hdel, hdst, j, k, line, e, lw, delim, strip, dd) {
  n = length(s); i = 1; st = 0; word = ""; have = 0; nw = 0; skipnext = 0; hdn = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (st == 1) { if (c == "\047") st = 0; else word = word c; i++; continue }
    if (st == 2) {
      if (c == "\\") { word = word substr(s, i + 1, 1); i += 2; continue }
      if (c == "\"") { st = 0; i++; continue }
      if (c == "$" && substr(s, i + 1, 1) == "(") { j = matchparen(s, i + 2); analyze(substr(s, i + 2, j - i - 2)); word = word "X"; i = j + 1; continue }
      if (c == "`") { j = index(substr(s, i + 1), "`"); if (j == 0) j = n - i + 1; analyze(substr(s, i + 1, j - 1)); word = word "X"; i += j + 1; continue }
      word = word c; i++; continue
    }
    if (c == "\\") {
      nx = substr(s, i + 1, 1)
      if (nx != "\n") { word = word nx; have = 1 }
      i += 2; continue
    }
    if (c == "\047") { st = 1; have = 1; i++; continue }
    if (c == "\"") { st = 2; have = 1; i++; continue }
    if (c == "#" && !have) { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
    if ((c == "$" || c == "<" || c == ">") && substr(s, i + 1, 1) == "(" && !(c != "$" && have)) {
      j = matchparen(s, i + 2); analyze(substr(s, i + 2, j - i - 2)); word = word "X"; have = 1; i = j + 1; continue
    }
    if (c == "`") { j = index(substr(s, i + 1), "`"); if (j == 0) j = n - i + 1; analyze(substr(s, i + 1, j - 1)); word = word "X"; have = 1; i += j + 1; continue }
    if (c == " " || c == "\t") {
      if (have) { if (skipnext) { skipnext = 0; word = ""; have = 0 } else { nw++; wd[nw] = word; word = ""; have = 0 } }
      i++; continue
    }
    if (c == "\n") {
      if (have) { if (skipnext) { skipnext = 0; word = ""; have = 0 } else { nw++; wd[nw] = word; word = ""; have = 0 } }
      { if (nw > 0) check(wd, nw); nw = 0; skipnext = 0 }
      i++
      # heredoc bodies of the line just ended are data: skip them up to their delimiter lines
      for (k = 1; k <= hdn; k++) {
        delim = hdel[k]; strip = hdst[k]
        while (i <= n) {
          e = index(substr(s, i), "\n")
          if (e == 0) { line = substr(s, i); i = n + 1 } else { line = substr(s, i, e - 1); i += e }
          if (strip) sub(/^\t+/, "", line)
          if (line == delim) break
        }
      }
      hdn = 0
      continue
    }
    if (c == "<" && substr(s, i + 1, 1) == "<" && substr(s, i + 2, 1) != "<") {
      if (have && word ~ /^[0-9]+$/) { word = ""; have = 0 } else if (have) { if (skipnext) { skipnext = 0; word = ""; have = 0 } else { nw++; wd[nw] = word; word = ""; have = 0 } }
      i += 2; strip = 0
      if (substr(s, i, 1) == "-") { strip = 1; i++ }
      while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
      delim = ""
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\047" || c == "\"") { i++; continue }
        if (c == " " || c == "\t" || c == "\n" || c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "<" || c == ">") break
        if (c == "\\") { i++; c = substr(s, i, 1) }
        delim = delim c; i++
      }
      hdn++; hdel[hdn] = delim; hdst[hdn] = strip
      continue
    }
    if (c == "<" || c == ">") {
      if (have && word ~ /^[0-9]+$/) { word = ""; have = 0 } else if (have) { if (skipnext) { skipnext = 0; word = ""; have = 0 } else { nw++; wd[nw] = word; word = ""; have = 0 } }
      skipnext = 1
      i++
      if (substr(s, i, 1) == c || substr(s, i, 1) == "&" || substr(s, i, 1) == "|") i++
      continue
    }
    if (c == "&" && (substr(s, i + 1, 1) == ">" )) { i++; continue }
    if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")") {
      if (have) { if (skipnext) { skipnext = 0; word = ""; have = 0 } else { nw++; wd[nw] = word; word = ""; have = 0 } }
      { if (nw > 0) check(wd, nw); nw = 0; skipnext = 0 }; i++; continue
    }
    word = word c; have = 1; i++
  }
  if (have) { if (skipnext) { skipnext = 0; word = ""; have = 0 } else { nw++; wd[nw] = word; word = ""; have = 0 } }
  { if (nw > 0) check(wd, nw); nw = 0; skipnext = 0 }
}
function check(w, n,    i, a, cmd, k, rest, m, r) {
  i = 1
  while (i <= n) {
    a = w[i]
    if (a ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
    if (a == "!" || a == "{" || a == "}" || a == "then" || a == "else" || a == "elif" || a == "do" || a == "if" || a == "while" || a == "until" || a == "fi" || a == "done" || a == "esac") { i++; continue }
    if (a == "env") { i++; while (i <= n && (w[i] ~ /^-/ || w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) { if (w[i] == "-u" || w[i] == "-C" || w[i] == "-S") i++; i++ } continue }
    if (a == "timeout") { i++; while (i <= n && w[i] ~ /^-/) { if (w[i] == "-s" || w[i] == "-k") i++; i++ } i++; continue }
    if (a == "nice") { i++; if (w[i] == "-n") i += 2; else if (w[i] ~ /^-/) i++; continue }
    if (a == "sudo") { i++; while (i <= n && w[i] ~ /^-/) { if (w[i] == "-u" || w[i] == "-g") i++; i++ } continue }
    if (a == "command") { i++; if (w[i] == "-v" || w[i] == "-V") return; while (i <= n && w[i] ~ /^-/) i++; continue }
    if (a == "nohup" || a == "exec" || a == "builtin" || a == "time") { i++; while (i <= n && w[i] ~ /^-/) i++; continue }
    break
  }
  if (i > n) return
  cmd = w[i]; sub(/.*\//, "", cmd)
  if (cmd == "for" || cmd == "case" || cmd == "select" || cmd == "function") return
  if (cmd == "sh" || cmd == "bash" || cmd == "zsh" || cmd == "dash" || cmd == "ksh") {
    for (k = i + 1; k < n; k++) if (w[k] ~ /^-[A-Za-z]*c[A-Za-z]*$/) { analyze(w[k + 1]); return }
    return
  }
  if (cmd == "eval") { rest = ""; for (k = i + 1; k <= n; k++) rest = rest " " w[k]; analyze(rest); return }
  if (cmd == "xargs") {
    k = i + 1
    while (k <= n && w[k] ~ /^-/) { if (w[k] ~ /^-[IniPLdEsa]$/) k++; k++ }
    m = 0; for (; k <= n; k++) { m++; r[m] = w[k] }
    if (m > 0) check(r, m)
    return
  }
  if (cmd == "codex") { for (k = i + 1; k <= n; k++) if (w[k] == "exec") { if (RES == "") RES = "codex-exec"; return } return }
  if (cmd == "omp") {
    if (n == i + 1 && w[i + 1] ~ /^(--version|-v|--help|-h)$/) return
    if (RES == "") RES = "omp"
  }
}
{ all = all (NR > 1 ? "\n" : "") $0 }
END { analyze(all); print RES }
' 2>/dev/null) || exit 0

case "$FOUND" in
  codex-exec) deny "Direct \`codex exec\` is a dropped legacy path. $USE_ENGINE" ;;
  omp) deny "Run omp only through scripts/omp-engine.sh, which pins the profile, the sandbox launcher and the model. $USE_ENGINE (omp --version and omp --help alone are fine.)" ;;
esac
exit 0

#!/bin/bash
# language-mode-smoke.sh — grep-based smoke test for LANGUAGE_MODE and the declared bootstrap tokens (Bash 3.2).
#
# Usage: /bin/bash .claude/scripts/tests/language-mode-smoke.sh
# Cases: rules/language-mode.md exists, is path-scoped (the preamble stays the only always-on rule), says `en` is
# the default and keeps code, identifiers, commit messages, PR titles and engine briefs English; LANGUAGE_MODE,
# STAGING_BRANCH, PROD_BRANCH and TICKET_PREFIX are each declared exactly once in agents/bootstrap/orchestrator.md;
# no token is declared twice; commands/bootstrap-project.md and CLAUDE.md.template only use tokens that list
# declares, and the template uses the four new ones. Prints the harness tokens that no list declares (info only).
# Exit 1 on any FAIL.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
ORCH="$ROOT/agents/bootstrap/orchestrator.md"
CMD="$ROOT/commands/bootstrap-project.md"
TPL="$ROOT/CLAUDE.md.template"
RULE="$ROOT/rules/language-mode.md"
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }
pass_if() { if "${@:2}"; then ok "$1"; else fail "$1"; fi; }

for f in "$ORCH" "$CMD" "$TPL" "$RULE"; do
  [ -f "$f" ] || { fail "exists: ${f#"$ROOT"/}"; }
done
[ "$FAILS" -eq 0 ] || exit 1

# tokens_in <file>: the distinct {{UPPER_CASE}} names in a file, one per line (the literal {{TOKEN}} excluded).
tokens_in() { grep -oE '\{\{[A-Z][A-Z_]*\}\}' "$1" | sort -u | grep -vx '{{TOKEN}}'; }

# The orchestrator's token list: its "The token set" section, up to the next heading.
LIST="$(awk '/^## The token set/ {on = 1; next} /^## / {on = 0} on' "$ORCH")"
LIST_TOKENS="$(printf '%s\n' "$LIST" | grep -oE '\{\{[A-Z][A-Z_]*\}\}' | sort -u)"

# Each new token: once in the whole orchestrator file, and in the list.
for t in LANGUAGE_MODE STAGING_BRANCH PROD_BRANCH TICKET_PREFIX; do
  n="$(grep -oF "{{$t}}" "$ORCH" | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ] && ok "$t declared exactly once in the orchestrator" || fail "$t declared exactly once in the orchestrator" "found $n"
  printf '%s\n' "$LIST_TOKENS" | grep -qxF "{{$t}}" && ok "$t is in the token set section" || fail "$t is in the token set section"
done

# No token is declared twice in the list.
DUPES="$(printf '%s\n' "$LIST" | grep -oE '\{\{[A-Z][A-Z_]*\}\}' | sort | uniq -d)"
[ -z "$DUPES" ] && ok 'no token is declared twice in the list' || fail 'no token is declared twice in the list' "$DUPES"

# The command and the template agree with the list.
for f in "$CMD" "$TPL"; do
  extra="$(tokens_in "$f" | while IFS= read -r t; do printf '%s\n' "$LIST_TOKENS" | grep -qxF "$t" || echo "$t"; done)"
  [ -z "$extra" ] && ok "${f#"$ROOT"/} uses only declared tokens" || fail "${f#"$ROOT"/} uses only declared tokens" "$(echo "$extra" | tr '\n' ' ')"
done
for t in LANGUAGE_MODE STAGING_BRANCH PROD_BRANCH TICKET_PREFIX; do
  grep -qF "{{$t}}" "$TPL" && ok "CLAUDE.md.template carries $t" || fail "CLAUDE.md.template carries $t"
done
grep -qF 'agents/bootstrap/orchestrator.md' "$CMD" && ok 'bootstrap-project points at the orchestrator list' || fail 'bootstrap-project points at the orchestrator list'

# The rule.
head -n 1 "$RULE" | grep -qx -- '---' && sed -n '2,6p' "$RULE" | grep -q '^paths:' && ok 'the rule is path-scoped' || fail 'the rule is path-scoped'
for r in "$ROOT"/rules/*.md; do
  case "$(basename "$r")" in README.md|behavioral-preamble.md) continue ;; esac
  grep -q '^paths:' "$r" && ok "$(basename "$r") is path-scoped" || fail "$(basename "$r") is path-scoped (the preamble is the only always-on rule)"
done
grep -qF '`en` (the default' "$RULE" && ok 'the rule says en is the default' || fail 'the rule says en is the default'
grep -qF '`ro`' "$RULE" && ok 'the rule describes ro' || fail 'the rule describes ro'
grep -qF 'ă â î ș ț' "$RULE" && ok 'the rule names the Romanian diacritics' || fail 'the rule names the Romanian diacritics'
for w in 'Commit messages' 'PR titles' 'omp:<engine>' 'Code, identifiers'; do
  grep -qF "$w" "$RULE" && ok "the rule keeps '$w' English" || fail "the rule keeps '$w' English"
done
grep -qF 'LANGUAGE_MODE' "$RULE" && ok 'the rule names the token' || fail 'the rule names the token'
grep -qF 'rules/language-mode.md' "$TPL" && ok 'the template points at the rule' || fail 'the template points at the rule'
grep -qF '`en` is the default' "$TPL" && ok 'the template says en is the default' || fail 'the template says en is the default'
grep -qF 'rules/language-mode.md' "$ORCH" && ok 'the orchestrator points at the rule' || fail 'the orchestrator points at the rule'

# Info only: harness tokens no list declares (they belong to other templated files).
UNDECLARED="$(cd "$ROOT" && grep -rhoE '\{\{[A-Z][A-Z_]*\}\}' agents commands skills hooks rules docs 2>/dev/null | sort -u \
  | while IFS= read -r t; do printf '%s\n' "$LIST_TOKENS" | grep -qxF "$t" || echo "$t"; done | grep -vx '{{TOKEN}}' | tr '\n' ' ')"
echo "info tokens used elsewhere in the harness that the list does not declare: ${UNDECLARED:-none}"

[ "$FAILS" -eq 0 ]

#!/bin/bash
# no-codex-smoke.sh — the codex-free gate (AC-061) and its counter, outside packs/ (Bash 3.2, no network).
#
# Usage: /bin/bash .claude/scripts/tests/no-codex-smoke.sh [--strict]
# Part 1 checks the counter on a throwaway tree: it finds each retired Codex string, ignores `packs/`, `.git`
# and the allowed names (`omp:codex`, `openai-codex`, `glen-harness-codex`), and reports a broad 'codex' count.
# Part 2 reports the same counts for the real tree. The real-tree gate is NON-BLOCKING until the prose gate
# (migration Step 45): it prints the counts and still exits 0. With --strict (or NO_CODEX_STRICT=1) any retired
# string left in the real tree is a FAIL. Part 1 failures always fail the run.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
STRICT="${NO_CODEX_STRICT:-0}"
[ "${1:-}" = --strict ] && STRICT=1
TMP="$(mktemp -d "${TMPDIR:-/tmp}/no-codex-smoke.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }

# The AC-061 strings, assembled from pieces so this file never matches itself.
C=codex
RETIRED="$C:$C-rescue
$C-companion
$C exec
$C review
sweep-$C-orphans
CODEX_COMPANION
coder-$C
/$C-advisor"
RETIRED_FILE="$TMP/retired.txt"
printf '%s\n' "$RETIRED" | tr -d '\r' >"$RETIRED_FILE"

# The intentional mentions in the real tree. Each entry is `path|reason`; a path ending in / allows the whole
# directory. Everything else that holds a retired string is a failure under --strict. Pack payloads under
# packs/ are excluded separately, and this file is excluded by name.
ALLOW='hooks/block-legacy-engines.sh|the hook that DENIES `codex exec`; the string is its match target
hooks/README.md|documents that hook and what it denies
scripts/tests/hooks-smoke.sh|the hook smoke feeds `codex exec` and the companion name to the deny/allow cases
scripts/tests/retired-refs-smoke.sh|the retired-name list of the reference check
scripts/close-run.sh|calls the codex pack'"'"'s orphan sweep only when the pack installed that script (guarded by a file check)
scripts/remove-worktree.sh|refuses on live native-Codex jobs and prints the companion cancel hint, only when the codex pack is installed
scripts/README.md|rows for the two scripts the codex pack ships and core scripts source optionally'
ALLOW_FILE="$TMP/allow.txt"
printf '%s\n' "$ALLOW" | cut -d'|' -f1 >"$ALLOW_FILE"
# allowed_filter: drop grep -n output lines (./path:N:text) whose path is allow-listed.
allowed_filter() {
  local line path keep a
  while IFS= read -r line; do
    path="${line#./}"; path="${path%%:*}"; keep=1
    while IFS= read -r a; do
      case "$a" in */) case "$path" in "$a"*) keep=0 ;; esac ;; *) [ "$path" = "$a" ] && keep=0 ;; esac
    done <"$ALLOW_FILE"
    [ "$keep" = 1 ] && printf '%s\n' "$line"
  done
}

# retired_hits <root>: lines holding a retired string, outside .git, packs/ and this file.
retired_hits() {
  (cd "$1" && grep -rInF -f "$RETIRED_FILE" --exclude-dir=.git --exclude-dir=packs --exclude-dir=node_modules \
    --exclude=no-codex-smoke.sh . 2>/dev/null)
}
# broad_count <root>: lines still saying 'codex' once the allowed names are removed.
broad_count() {
  (cd "$1" && grep -rIni --exclude-dir=.git --exclude-dir=packs --exclude-dir=node_modules \
    --exclude=no-codex-smoke.sh "$C" . 2>/dev/null) \
    | sed -e "s/omp:$C//g" -e "s/openai-$C//g" -e "s/glen-harness-$C//g" \
    | grep -ci "$C"
}

F="$TMP/fixture"
mkdir -p "$F/agents" "$F/packs/codex" "$F/.git" "$F/docs"
printf 'dispatch %s:%s-rescue now\n' "$C" "$C" >"$F/agents/a.md"
printf 'run %s exec here\n' "$C" >"$F/agents/b.md"
printf 'run %s review here\n' "$C" >"$F/agents/c.md"
printf 'the %s_COMPANION variable\n' "$(printf '%s' "$C" | tr a-z A-Z)" >"$F/agents/d.md"
printf 'uses omp:%s and openai-%s and glen-harness-%s\n' "$C" "$C" "$C" >"$F/docs/allowed.md"
printf 'a pack may say %s exec and %s review freely\n' "$C" "$C" >"$F/packs/codex/x.md"
printf '%s exec in git\n' "$C" >"$F/.git/config"
printf 'sweep-%s-orphans and coder-%s and /%s-advisor\n' "$C" "$C" "$C" >"$F/agents/e.md"

HITS="$(retired_hits "$F")"
for want in 'agents/a.md' 'agents/b.md' 'agents/c.md' 'agents/d.md' 'agents/e.md'; do
  printf '%s\n' "$HITS" | grep -qF "$want" && ok "counter finds $want" || fail "counter finds $want" "$HITS"
done
printf '%s\n' "$HITS" | grep -qF 'packs/' && fail 'counter ignores packs/' "$HITS" || ok 'counter ignores packs/'
printf '%s\n' "$HITS" | grep -qF '.git' && fail 'counter ignores .git' "$HITS" || ok 'counter ignores .git'
printf '%s\n' "$HITS" | grep -qF 'allowed.md' && fail 'allowed names are not retired strings' "$HITS" || ok 'allowed names are not retired strings'
n="$(broad_count "$F")"
[ "$n" -eq 5 ] && ok "broad count ignores allowed names and packs (5)" || fail 'broad count ignores allowed names and packs' "got $n, want 5"
mkdir -p "$F/hooks"
printf 'deny %s exec here\n' "$C" >"$F/hooks/block-legacy-engines.sh"
AL="$(retired_hits "$F" | allowed_filter)"
printf '%s\n' "$AL" | grep -qF 'block-legacy-engines' && fail 'allow-list drops an allow-listed file' "$AL" || ok 'allow-list drops an allow-listed file'
printf '%s\n' "$AL" | grep -qF 'agents/a.md' && ok 'allow-list keeps other files' || fail 'allow-list keeps other files' "$AL"
mkdir -p "$TMP/clean"
printf 'nothing here, only omp:%s\n' "$C" >"$TMP/clean/x.md"
[ -z "$(retired_hits "$TMP/clean")" ] && [ "$(broad_count "$TMP/clean")" -eq 0 ] && ok 'a clean tree counts zero' || fail 'a clean tree counts zero'

# Part 2: the real tree, minus the allow-listed files above.
ALLOWED_N="$(retired_hits "$ROOT" | wc -l | tr -d ' ')"
REAL_HITS="$(retired_hits "$ROOT" | allowed_filter)"
REAL="$(printf '%s' "$REAL_HITS" | grep -c . || true)"
echo "info $((ALLOWED_N - REAL)) allow-listed line(s) in $(wc -l <"$ALLOW_FILE" | tr -d ' ') file(s) or dirs (reasons in this file)"
BROAD="$(broad_count "$ROOT")"
echo "info retired Codex strings outside packs/: $REAL line(s); lines mentioning 'codex' beyond the allowed names: $BROAD"
if [ "$REAL" -gt 0 ]; then
  printf '%s\n' "$REAL_HITS" | cut -d: -f1 | sort | uniq -c | sort -rn | head -n 8 | sed 's/^/info   /'
  if [ "$STRICT" = 1 ]; then
    fail 'real tree is codex-free' "$REAL line(s)"
  else
    echo "note non-blocking until the prose gate (Step 45); re-run with --strict to enforce"
  fi
else
  ok 'real tree is codex-free'
fi

[ "$FAILS" -eq 0 ]

#!/bin/bash
# security-lens-smoke.sh — the security audit's domain-integrity lens is an explicitly configured template (Bash 3.2).
#
# Usage: /bin/bash .claude/scripts/tests/security-lens-smoke.sh
# Grep-based: the template lives in templates/ with its STUB TEMPLATE marker; no domain-integrity.md ships in the
# audit folder; the orchestrator carries the configured/unconfigured check and the explicit skip; and the check
# snippet itself classifies a missing file, a stub copy and a filled copy correctly. Exit 1 on any FAIL.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/security-lens-smoke.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }
T="$ROOT/templates/security-domain-integrity.md"
O="$ROOT/agents/codebase/security-audit/orchestrator.md"

[ -f "$T" ] && grep -q 'STUB TEMPLATE' "$T" && ok 'the template exists and carries the STUB TEMPLATE marker' || fail 'template or marker'
[ ! -e "$ROOT/agents/codebase/security-audit/domain-integrity.md" ] && ok 'no domain-integrity.md ships as an agent' || fail 'domain-integrity.md ships in agents/'
grep -q "grep -q 'STUB TEMPLATE'" "$O" && ok 'the orchestrator checks for the stub marker' || fail 'orchestrator check'
grep -q 'skip the lens explicitly' "$O" && grep -q 'skipped (not configured)' "$O" && ok 'the orchestrator skips an unconfigured lens explicitly and reports it' || fail 'orchestrator skip wording'

classify() { # the orchestrator's snippet, run against a file path
  f="$1"
  if [ -f "$f" ] && ! grep -q 'STUB TEMPLATE' "$f"; then echo configured; else echo unconfigured; fi
}
[ "$(classify "$TMP/none.md")" = unconfigured ] && ok 'a missing file is unconfigured' || fail 'missing file'
cp "$T" "$TMP/stub.md"
[ "$(classify "$TMP/stub.md")" = unconfigured ] && ok 'an unedited copy of the template is unconfigured' || fail 'stub copy'
printf '# Tenant isolation\nAudit row-level isolation.\n' >"$TMP/real.md"
[ "$(classify "$TMP/real.md")" = configured ] && ok 'a filled-in copy is configured' || fail 'filled copy'

[ "$FAILS" -eq 0 ]

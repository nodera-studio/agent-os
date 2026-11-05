#!/bin/bash
# retired-refs-smoke.sh — no file outside packs/ may still name an agent, command, skill or script the harness
# retired (Bash 3.2, no network).
#
# Usage: /bin/bash .claude/scripts/tests/retired-refs-smoke.sh
# Runs scripts/check-refs.sh --exclude-packs over the whole harness tree with the retired names below. Add a
# line to RETIRED whenever a file is cut or moved into a pack; a hit means an inbound reference was missed.
# This file and docs/CHANGELOG.md are excluded from the scan because they have to spell the names. Exit 1 on any hit.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
SELF_REL="scripts/tests/retired-refs-smoke.sh"
CHANGELOG_REL="docs/CHANGELOG.md" # the migration summary has to name every retired file
# With HARNESS_SMOKE_PACKS the fixture carries pack payloads in .claude/, which would trip every group.
if [ -e "$ROOT/commands/orchestrate.md" ] || [ -e "$ROOT/commands/copywrite.md" ] || [ -e "$ROOT/skills/codex/SKILL.md" ]; then
  echo "ok   skipped: pack payloads are in this tree (HARNESS_SMOKE_PACKS)"; exit 0
fi
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }

# <label>|<needle> <needle> ...   (one group per cut, so a failure names the cut)
RETIRED='
docs-expert|docs-expert codebase-docs-expert
quick-lanes|implement-quick orchestrator-quick quick-classify
coder-codex|coder-codex impl-coder-codex
skill-mnemosyne|skills/mnemosyne/SKILL.md
skill-wrangler|skills/wrangler
skill-codex|skills/codex/SKILL.md
core-codex-hook|block-old-codex
learned-rules-hook|mnemosyne-capture
copywrite-pack|agents/copywrite commands/copywrite.md apple-style-guide voice-rubric microcopy-specialist localization-editor consistency-checker voice-editor
queue-agents-pack|debug/queue.md
skills-moved-to-packs|skills/linear skills/sentry-cli skills/playwright-cli
security-scan-pack|commands/security-scan.md docs/config-security.md
orchestrator-pack|commands/orchestrate.md commands/audit-agent-gaps.md agents/orchestrator/ scripts/orchestrator/ record-gap gap-auditor orchestrator-mode.md GapLog gaps.jsonl
'

while IFS='|' read -r label needles; do
  [ -n "$label" ] || continue
  # shellcheck disable=SC2086
  if OUT="$(/bin/bash "$ROOT/scripts/check-refs.sh" --root "$ROOT" --exclude-packs --exclude "$SELF_REL" --exclude "$CHANGELOG_REL" $needles 2>&1)"; then
    ok "no reference to retired $label"
  else
    fail "no reference to retired $label" "$(printf '%s\n' "$OUT" | head -n 6)"
  fi
done <<EOF2
$RETIRED
EOF2

[ "$FAILS" -eq 0 ]

#!/usr/bin/env bash
# install.sh — drop the agent-os harness into a target project's .claude/ directory.
#
# Usage: ./install.sh <target-project-path>
#
# Copies this repo's agents/, commands/, skills/, hooks/, rules/, docs/, scripts/,
# prompts/, plugin/, the scaffold dirs (plans/, research/, tech-debt/, testing/,
# evidence/, handoffs/), settings.json, and CLAUDE.md.template into
# <target>/.claude/. Never overwrites an existing <target>/.claude/settings.json
# or <target>/.claude/CLAUDE.md — those are skipped with a warning if present, so
# a re-run never clobbers project-specific customization.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <target-project-path>" >&2
  exit 1
fi

TARGET_PROJECT="$1"

if [ ! -d "$TARGET_PROJECT" ]; then
  echo "install.sh: target path does not exist or is not a directory: $TARGET_PROJECT" >&2
  exit 1
fi

TARGET_CLAUDE="$TARGET_PROJECT/.claude"
mkdir -p "$TARGET_CLAUDE"

# Directories copied wholesale (safe to overwrite — this harness owns them).
DIRS=(agents commands skills hooks rules docs scripts prompts plugin plans research tech-debt testing evidence handoffs)

copy_dir() {
  local name="$1"
  local src="$SOURCE_DIR/$name"
  local dest="$TARGET_CLAUDE/$name"
  [ -d "$src" ] || return 0
  mkdir -p "$dest"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$src/" "$dest/"
  else
    cp -r "$src/." "$dest/"
  fi
  echo "install.sh: synced $name/"
}

for d in "${DIRS[@]}"; do
  copy_dir "$d"
done

# settings.json and CLAUDE.md.template: never clobber an existing settings.json
# or CLAUDE.md in the target — those carry project-specific customization once
# /bootstrap-project has run.
if [ -f "$TARGET_CLAUDE/settings.json" ]; then
  echo "install.sh: WARNING — $TARGET_CLAUDE/settings.json already exists, skipping (not overwritten)"
else
  cp "$SOURCE_DIR/settings.json" "$TARGET_CLAUDE/settings.json"
  echo "install.sh: wrote settings.json"
fi

if [ -f "$TARGET_CLAUDE/CLAUDE.md" ]; then
  echo "install.sh: WARNING — $TARGET_CLAUDE/CLAUDE.md already exists, skipping (not overwritten)"
else
  cp "$SOURCE_DIR/CLAUDE.md.template" "$TARGET_CLAUDE/CLAUDE.md"
  echo "install.sh: wrote CLAUDE.md (from CLAUDE.md.template — fill in the {{TOKEN}} placeholders)"
fi

if [ -f "$SOURCE_DIR/lefthook.yml" ]; then
  if [ -f "$TARGET_PROJECT/lefthook.yml" ]; then
    echo "install.sh: WARNING — $TARGET_PROJECT/lefthook.yml already exists, skipping (not overwritten)"
  else
    cp "$SOURCE_DIR/lefthook.yml" "$TARGET_PROJECT/lefthook.yml"
    echo "install.sh: wrote lefthook.yml"
  fi
fi

echo ""
echo "install.sh: done. Now run /bootstrap-project inside Claude Code in the target project to customize it."

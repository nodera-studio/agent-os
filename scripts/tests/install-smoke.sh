#!/bin/bash
# install-smoke.sh — smoke test for install.sh and its pack manager (Bash 3.2, no network).
#
# Usage: /bin/bash .claude/scripts/tests/install-smoke.sh
# Part 1 installs the real harness tree into throwaway targets: fresh and repeated install, templates/ copied,
#   hand-edited settings.json and CLAUDE.md survive, user files are never deleted, plugin symlinks resolve,
#   rsync and the cp fallback produce the same tree, no rsync --delete in the script, jq missing.
# Part 2 uses a fake harness checkout with fixture packs (the real packs/ is not touched): list, install, repeat
#   (byte-identical settings.json and manifest), hand-edited and duplicate hooks, routing fragment, upgrade with
#   a modified file, removal with a modified file, unmanaged and pre-manifest files, prior hashes, broken
#   settings.json, missing dependencies, invalid manifests, broken plugin links.
# Exit 1 on any FAIL.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SRC="$(cd "$HERE/../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/install-smoke.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }
need() { command -v "$1" >/dev/null 2>&1 || { echo "FAIL: $1 not installed"; exit 1; }; }
need jq
need git

sig() { cksum <"$1" | awk '{print $1 ":" $2}'; }
# run_install <install.sh> <args...>: sets OUT (stdout and stderr) and RC.
run_install() {
  local script="$1"; shift
  OUT="$(/bin/bash "$script" "$@" 2>&1)"; RC=$?
}
expect_rc() { if [ "$RC" -eq "$2" ]; then ok "$1"; else fail "$1" "rc=$RC want $2: $OUT"; fi; }
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$2" && ok "$1" || fail "$1" "missing '$2' in: $OUT"; }
out_lacks() { printf '%s\n' "$OUT" | grep -qF -- "$2" && fail "$1" "unexpected '$2' in: $OUT" || ok "$1"; }
pass_if() { if "${@:2}"; then ok "$1"; else fail "$1"; fi; }
fail_if() { if "${@:2}"; then fail "$1"; else ok "$1"; fi; }
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# tree_sig <dir>: file hashes, symlink targets and executable files of a tree.
tree_sig() {
  (cd "$1" && {
    find . -type f | sort | while IFS= read -r f; do echo "F $f $(sha_of "$f")"; done
    find . -type l | sort | while IFS= read -r l; do echo "L $l $(readlink "$l")"; done
    find . -type f -perm -u+x | sort | sed 's/^/X /'
  })
}

# ---------------------------------------------------------------------------------------------------------
# Part 1: the real harness tree
# ---------------------------------------------------------------------------------------------------------
INSTALL="$SRC/install.sh"
T1="$TMP/t1"; mkdir -p "$T1"
run_install "$INSTALL" "$T1"
expect_rc 'fresh install exits 0' 0
pass_if 'templates/ is copied' test -f "$T1/.claude/templates/auto-mode-state.md"
pass_if 'settings.json seeded' test -f "$T1/.claude/settings.json"
pass_if 'routing.json seeded' test -f "$T1/.claude/routing.json"
pass_if 'CLAUDE.md seeded' test -f "$T1/.claude/CLAUDE.md"
pass_if 'no manifest without packs' test ! -e "$T1/.claude/packs.lock.json"
fail_if 'packs/ is not copied into the target' test -e "$T1/.claude/packs"
for c in agents commands hooks skills; do
  pass_if "plugin symlink $c resolves in the target" test -d "$T1/.claude/plugin/agent-os-workflow/$c/"
done
pass_if 'plugin symlinks stay symlinks' test -L "$T1/.claude/plugin/agent-os-workflow/agents"

# Repeat on top of customization: nothing the project owns is clobbered, nothing is deleted.
printf '{"hand":"edited"}\n' >"$T1/.claude/settings.json"
printf 'my project notes\n' >"$T1/.claude/CLAUDE.md"
printf 'user agent\n' >"$T1/.claude/agents/my-own-agent.md"
printf '{"custom":true}\n' >"$T1/.claude/routing.json"
run_install "$INSTALL" "$T1"
expect_rc 'repeated install exits 0' 0
[ "$(cat "$T1/.claude/settings.json")" = '{"hand":"edited"}' ] && ok 'edited settings.json survives' || fail 'edited settings.json survives'
[ "$(cat "$T1/.claude/CLAUDE.md")" = 'my project notes' ] && ok 'edited CLAUDE.md survives' || fail 'edited CLAUDE.md survives'
[ "$(cat "$T1/.claude/routing.json")" = '{"custom":true}' ] && ok 'edited routing.json survives' || fail 'edited routing.json survives'
pass_if 'user file in a harness directory survives' test -f "$T1/.claude/agents/my-own-agent.md"
out_has 'a skipped settings.json is announced' 'settings.json already exists'
out_has 'a differing routing.json says how to adopt the new defaults' 'new engine defaults are not applied'

# Upgrade from an older install: a stale file the harness no longer ships is left alone.
printf 'stale\n' >"$T1/.claude/scripts/removed-long-ago.sh"
run_install "$INSTALL" "$T1"
pass_if 'a file the harness stopped shipping is not deleted' test -f "$T1/.claude/scripts/removed-long-ago.sh"

# rsync and the cp fallback give the same tree.
T2="$TMP/t2"; mkdir -p "$T2"
OUT="$(INSTALL_NO_RSYNC=1 /bin/bash "$INSTALL" "$T2" 2>&1)"; RC=$?
expect_rc 'cp fallback install exits 0' 0
T3="$TMP/t3"; mkdir -p "$T3"
run_install "$INSTALL" "$T3"
tree_sig "$T3/.claude" >"$TMP/sig-rsync"
tree_sig "$T2/.claude" >"$TMP/sig-cp"
if cmp -s "$TMP/sig-rsync" "$TMP/sig-cp"; then ok 'rsync and cp trees are identical (files, links, exec bits)'; else
  fail 'rsync and cp trees are identical' "$(diff "$TMP/sig-rsync" "$TMP/sig-cp" | head -n 6)"; fi
for c in agents commands hooks skills; do
  pass_if "cp fallback keeps plugin symlink $c resolving" test -d "$T2/.claude/plugin/agent-os-workflow/$c/"
done

fail_if 'no rsync --delete in the installer' sh -c "grep -v '^[[:space:]]*#' '$INSTALL' | grep -q -- '--delete'"

# jq is required, with a clear message.
NOJQ="$TMP/bin-nojq"; mkdir -p "$NOJQ"
for t in dirname cat; do ln -s "$(command -v "$t")" "$NOJQ/$t"; done
OUT="$(PATH="$NOJQ" /bin/bash "$INSTALL" "$TMP/t-nojq" 2>&1)"; RC=$?
expect_rc 'missing jq exits 1' 1
out_has 'missing jq is explained' 'jq is required'

run_install "$INSTALL"
expect_rc 'no target exits 1' 1
run_install "$INSTALL" "$TMP/does-not-exist"
expect_rc 'missing target exits 1' 1
run_install "$INSTALL" "$T1" --bogus
expect_rc 'unknown option exits 1' 1

# ---------------------------------------------------------------------------------------------------------
# Part 2: a fake checkout with fixture packs
# ---------------------------------------------------------------------------------------------------------
F="$TMP/fake"; mkdir -p "$F"
cp "$INSTALL" "$F/install.sh"
cp "$SRC/settings.json" "$F/settings.json"
cp "$SRC/CLAUDE.md.template" "$F/CLAUDE.md.template"
printf '{"omp_fallback":[],"heavy_concurrency":8}\n' >"$F/routing.json"
mkdir -p "$F/agents" "$F/commands" "$F/hooks" "$F/skills" "$F/plugin/agent-os-workflow"
printf 'core agent\n' >"$F/agents/core.md"
for c in agents commands hooks skills; do ln -s "../../$c" "$F/plugin/agent-os-workflow/$c"; done
FI="$F/install.sh"

mkpack() { mkdir -p "$F/packs/$1"; }
# alpha: two files, a hook in two events, a routing fragment with a set and an unset key.
mkpack alpha
mkdir -p "$F/packs/alpha/agents/alpha" "$F/packs/alpha/hooks"
printf 'alpha agent v1\n' >"$F/packs/alpha/agents/alpha/agent.md"
printf '#!/bin/bash\necho alpha v1\n' >"$F/packs/alpha/hooks/alpha.sh"; chmod +x "$F/packs/alpha/hooks/alpha.sh"
cat >"$F/packs/alpha/pack.json" <<'JSON'
{
  "name": "alpha",
  "version": "1",
  "description": "Alpha fixture pack",
  "files": ["agents/alpha/agent.md", "hooks/alpha.sh"],
  "hooks": [
    {"event": "PreToolUse", "matcher": "Bash", "command": ".claude/hooks/alpha.sh"},
    {"event": "SessionStart", "command": ".claude/hooks/alpha.sh", "timeout": 5}
  ],
  "routing": {"omp_fallback": ["codex"], "alpha_cap": 3}
}
JSON
# beta: depends on alpha.
mkpack beta
mkdir -p "$F/packs/beta/skills/beta"
printf 'beta skill\n' >"$F/packs/beta/skills/beta/SKILL.md"
printf '{"name":"beta","files":["skills/beta/SKILL.md"],"requires":["pack:alpha"],"description":"Needs alpha"}\n' >"$F/packs/beta/pack.json"
# needs-tool: a command that does not exist.
mkpack needs-tool
mkdir -p "$F/packs/needs-tool/scripts"
printf 'x\n' >"$F/packs/needs-tool/scripts/t.sh"
printf '{"name":"needs-tool","files":["scripts/t.sh"],"requires":["cmd:no-such-binary-for-install-smoke"]}\n' >"$F/packs/needs-tool/pack.json"
# prior: ships a file a pre-manifest install may already hold.
mkpack prior
mkdir -p "$F/packs/prior/scripts"
printf 'prior v2\n' >"$F/packs/prior/scripts/p.sh"
PRIOR_V1="$(printf 'prior v1\n' >"$TMP/p1"; sha_of "$TMP/p1")"
printf '{"name":"prior","files":["scripts/p.sh"],"prior_hashes":{"scripts/p.sh":["%s"]}}\n' "$PRIOR_V1" >"$F/packs/prior/pack.json"

run_install "$FI" --list-packs
expect_rc '--list-packs without a target exits 0' 0
out_has 'list shows alpha' 'alpha'
out_has 'list shows the description' 'Alpha fixture pack'
out_has 'list shows beta' 'beta'

TA="$TMP/ta"; mkdir -p "$TA"
S="$TA/.claude/settings.json"; L="$TA/.claude/packs.lock.json"

# Missing dependencies change nothing.
run_install "$FI" "$TA" --pack needs-tool
expect_rc 'missing command requirement exits 1' 1
out_has 'missing command is named' 'no-such-binary-for-install-smoke'
pass_if 'a failed requirement leaves the target untouched' test ! -e "$TA/.claude"
run_install "$FI" "$TA" --pack beta
expect_rc 'missing pack requirement exits 1' 1
out_has 'missing pack is named' 'requires pack alpha'
pass_if 'a failed pack requirement leaves the target untouched' test ! -e "$TA/.claude"
run_install "$FI" "$TA" --pack nope
expect_rc 'unknown pack exits 1' 1
run_install "$FI" "$TA" --pack alpha --remove-pack alpha
expect_rc 'install and remove of one pack in one call exits 1' 1
run_install "$FI" "$TA" --remove-pack alpha
expect_rc 'removing a pack that is not installed exits 1' 1

# Install alpha.
run_install "$FI" "$TA" --pack alpha
expect_rc 'pack install exits 0' 0
pass_if 'pack file installed' test -f "$TA/.claude/agents/alpha/agent.md"
pass_if 'pack hook script keeps its exec bit' test -x "$TA/.claude/hooks/alpha.sh"
pass_if 'plain install ran first' test -f "$TA/.claude/agents/core.md"
pass_if 'manifest written' test -f "$L"
[ "$(jq -r '.packs.alpha.files["agents/alpha/agent.md"]' "$L")" = "$(sha_of "$TA/.claude/agents/alpha/agent.md")" ] \
  && ok 'manifest holds the sha256 of each file' || fail 'manifest holds the sha256 of each file'
[ "$(jq -r '.packs.alpha.files | length' "$L")" = 2 ] && ok 'manifest lists both files' || fail 'manifest lists both files'
[ "$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == ".claude/hooks/alpha.sh")] | length' "$S")" = 1 ] \
  && ok 'hook merged under its matcher' || fail 'hook merged under its matcher'
[ "$(jq '[.hooks.SessionStart[] | .hooks[] | select(.command == ".claude/hooks/alpha.sh")] | length' "$S")" = 1 ] \
  && ok 'hook merged into a second event' || fail 'hook merged into a second event'
[ "$(jq '[.hooks.SessionStart[] | .hooks[] | select(.command == ".claude/hooks/alpha.sh")][0].timeout' "$S")" = 5 ] \
  && ok 'hook timeout kept' || fail 'hook timeout kept'
[ "$(jq -c '.omp_fallback' "$TA/.claude/routing.json")" = '[]' ] && ok 'a set routing key is not overwritten' || fail 'a set routing key is not overwritten'
[ "$(jq -c '.alpha_cap' "$TA/.claude/routing.json")" = 3 ] && ok 'an unset routing key is merged' || fail 'an unset routing key is merged'
valid_json() { jq -e . "$1" >/dev/null 2>&1; }
pass_if 'settings.json stays valid JSON' valid_json "$S"
run_install "$FI" --list-packs "$TA"
out_has 'list shows installed state' 'installed'

# Idempotent.
SS="$(sig "$S")"; LS="$(sig "$L")"; RS="$(sig "$TA/.claude/routing.json")"
run_install "$FI" "$TA" --pack alpha
expect_rc 'repeat pack install exits 0' 0
[ "$(sig "$S")" = "$SS" ] && ok 'repeat leaves settings.json byte-identical' || fail 'repeat leaves settings.json byte-identical'
[ "$(sig "$L")" = "$LS" ] && ok 'repeat leaves the manifest byte-identical' || fail 'repeat leaves the manifest byte-identical'
[ "$(sig "$TA/.claude/routing.json")" = "$RS" ] && ok 'repeat leaves routing.json byte-identical' || fail 'repeat leaves routing.json byte-identical'
[ "$(jq '[.. | objects | select(.command? == ".claude/hooks/alpha.sh")] | length' "$S")" = 2 ] && ok 'no duplicate hooks after repeats' || fail 'no duplicate hooks after repeats'

# A hand edit of settings.json survives a pack merge (a second pack-less run and a beta install).
jq '. + {"myKey": {"keep": true}} | .hooks.Stop += [{"hooks":[{"type":"command","command":"my-own-stop.sh"}]}]' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
run_install "$FI" "$TA" --pack beta
expect_rc 'dependent pack installs once its requirement is met' 0
[ "$(jq -c '.myKey' "$S")" = '{"keep":true}' ] && ok 'hand-edited settings key survives a pack merge' || fail 'hand-edited settings key survives a pack merge'
[ "$(jq '[.hooks.Stop[] | .hooks[] | select(.command == "my-own-stop.sh")] | length' "$S")" = 1 ] && ok 'hand-wired hook survives a pack merge' || fail 'hand-wired hook survives a pack merge'
run_install "$FI" "$TA" --remove-pack alpha
expect_rc 'removing a required pack exits 1' 1
out_has 'the dependent is named' 'required by installed pack beta'
run_install "$FI" "$TA" --remove-pack beta
expect_rc 'removing the dependent exits 0' 0
pass_if 'dependent pack file removed' test ! -e "$TA/.claude/skills/beta/SKILL.md"
pass_if 'empty directory pruned' test ! -d "$TA/.claude/skills/beta"
pass_if 'top-level directory kept' test -d "$TA/.claude/skills"

# Upgrade: an unchanged file is replaced, a modified one is kept and reported.
printf 'alpha agent v2\n' >"$F/packs/alpha/agents/alpha/agent.md"
printf '#!/bin/bash\necho alpha v2\n' >"$F/packs/alpha/hooks/alpha.sh"
printf 'my local edit\n' >>"$TA/.claude/hooks/alpha.sh"
OLD_HOOK_SHA="$(jq -r '.packs.alpha.files["hooks/alpha.sh"]' "$L")"
run_install "$FI" "$TA" --pack alpha
expect_rc 'upgrade with a modified file exits 3' 3
out_has 'conflict reported for the modified file' 'CONFLICT modified hooks/alpha.sh'
[ "$(cat "$TA/.claude/agents/alpha/agent.md")" = 'alpha agent v2' ] && ok 'unchanged file upgraded' || fail 'unchanged file upgraded'
grep -q 'my local edit' "$TA/.claude/hooks/alpha.sh" && ok 'modified file kept' || fail 'modified file kept'
[ "$(jq -r '.packs.alpha.files["hooks/alpha.sh"]' "$L")" = "$OLD_HOOK_SHA" ] && ok 'manifest keeps the old hash of a kept file' || fail 'manifest keeps the old hash of a kept file'
[ "$(jq -r '.packs.alpha.files["agents/alpha/agent.md"]' "$L")" = "$(sha_of "$TA/.claude/agents/alpha/agent.md")" ] && ok 'manifest hash follows the upgraded file' || fail 'manifest hash follows the upgraded file'

# Removal: modified files survive, the rest goes, hooks are unwired, routing key removed, partial entry kept.
run_install "$FI" "$TA" --remove-pack alpha
expect_rc 'removal with a modified file exits 3' 3
out_has 'removal reports the modified file' 'CONFLICT modified hooks/alpha.sh'
pass_if 'modified file survives removal' test -f "$TA/.claude/hooks/alpha.sh"
pass_if 'unchanged file removed' test ! -e "$TA/.claude/agents/alpha/agent.md"
pass_if 'empty pack directories pruned' test ! -d "$TA/.claude/agents/alpha"
[ "$(jq '[.. | objects | select(.command? == ".claude/hooks/alpha.sh")] | length' "$S")" = 0 ] && ok 'pack hooks unwired' || fail 'pack hooks unwired'
[ "$(jq '[.hooks.PreToolUse[] | select((.hooks | length) == 0)] | length' "$S")" = 0 ] && ok 'no empty hook group left behind' || fail 'no empty hook group left behind'
[ "$(jq '[.hooks.Stop[] | .hooks[] | select(.command == "my-own-stop.sh")] | length' "$S")" = 1 ] && ok 'hand-wired hook still there after removal' || fail 'hand-wired hook still there after removal'
[ "$(jq 'has("alpha_cap")' "$TA/.claude/routing.json")" = false ] && ok 'routing key the pack set is removed' || fail 'routing key the pack set is removed'
[ "$(jq -c '.omp_fallback' "$TA/.claude/routing.json")" = '[]' ] && ok 'routing key the pack did not set is untouched' || fail 'routing key the pack did not set is untouched'
[ "$(jq -r '.packs.alpha.partial' "$L")" = true ] && ok 'manifest keeps a partial entry' || fail 'manifest keeps a partial entry'
run_install "$FI" --list-packs "$TA"
out_has 'list shows a partly removed pack' 'partly removed'
rm -f "$TA/.claude/hooks/alpha.sh"
run_install "$FI" "$TA" --remove-pack alpha
expect_rc 'second removal after resolving the conflict exits 0' 0
[ "$(jq '.packs | has("alpha")' "$L")" = false ] && ok 'manifest entry dropped once nothing is left' || fail 'manifest entry dropped once nothing is left'

# A hook that was already wired by hand is not duplicated and is not removed with the pack.
TB="$TMP/tb"; mkdir -p "$TB/.claude"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":".claude/hooks/alpha.sh"}]}]},"x":1}' >"$TB/.claude/settings.json"
printf '{"heavy_concurrency":8}\n' >"$TB/.claude/routing.json"
printf '#!/bin/bash\necho alpha v2\n' >"$F/packs/alpha/hooks/alpha.sh"
run_install "$FI" "$TB" --pack alpha
expect_rc 'install over a hand-wired hook exits 0' 0
[ "$(jq '[.hooks.PreToolUse[] | .hooks[] | select(.command == ".claude/hooks/alpha.sh")] | length' "$TB/.claude/settings.json")" = 1 ] \
  && ok 'a command already wired is not duplicated' || fail 'a command already wired is not duplicated'
[ "$(jq -r '[.packs.alpha.hooks[] | select(.event == "PreToolUse")][0].added' "$TB/.claude/packs.lock.json")" = false ] \
  && ok 'the manifest records that the pack did not add it' || fail 'the manifest records that the pack did not add it'
run_install "$FI" "$TB" --remove-pack alpha
expect_rc 'removal exits 0' 0
[ "$(jq '[.hooks.PreToolUse[] | .hooks[] | select(.command == ".claude/hooks/alpha.sh")] | length' "$TB/.claude/settings.json")" = 1 ] \
  && ok 'a hook the pack did not add survives removal' || fail 'a hook the pack did not add survives removal'
[ "$(jq '.hooks | has("SessionStart")' "$TB/.claude/settings.json")" = false ] && ok 'the hook the pack did add is gone' || fail 'the hook the pack did add is gone'

# Unmanaged and pre-manifest files.
TC="$TMP/tc"; mkdir -p "$TC/.claude/agents/alpha" "$TC/.claude/hooks" "$TC/.claude/scripts"
printf 'somebody elses file\n' >"$TC/.claude/agents/alpha/agent.md"
printf '#!/bin/bash\necho alpha v2\n' >"$TC/.claude/hooks/alpha.sh"
run_install "$FI" "$TC" --pack alpha
expect_rc 'an unmanaged differing file gives a conflict (exit 3)' 3
out_has 'ambiguous ownership is reported' 'CONFLICT ambiguous-ownership agents/alpha/agent.md'
[ "$(cat "$TC/.claude/agents/alpha/agent.md")" = 'somebody elses file' ] && ok 'the ambiguous file is kept' || fail 'the ambiguous file is kept'
[ "$(jq '.packs.alpha.files | has("agents/alpha/agent.md")' "$TC/.claude/packs.lock.json")" = false ] && ok 'the ambiguous file is not claimed in the manifest' || fail 'the ambiguous file is not claimed in the manifest'
out_has 'an identical pre-existing file is adopted' 'adopted hooks/alpha.sh'
run_install "$FI" "$TC" --remove-pack alpha
pass_if 'removal does not delete the file it never owned' test -f "$TC/.claude/agents/alpha/agent.md"
printf 'prior v1\n' >"$TC/.claude/scripts/p.sh"
run_install "$FI" "$TC" --pack prior
expect_rc 'a pre-manifest file with a known prior hash is upgraded (exit 0)' 0
out_has 'the prior-hash replacement is announced' 'replaced scripts/p.sh'
[ "$(cat "$TC/.claude/scripts/p.sh")" = 'prior v2' ] && ok 'the file now holds the new version' || fail 'the file now holds the new version'
printf 'prior v1 edited\n' >"$TC/.claude/scripts/p.sh"
run_install "$FI" "$TC" --remove-pack prior
expect_rc 'a modified owned file survives removal (exit 3)' 3
pass_if 'file kept' test -f "$TC/.claude/scripts/p.sh"

# Settings conflicts: a settings.json the merge cannot use is reported and never touched.
TD="$TMP/td"; mkdir -p "$TD/.claude"
printf 'this is not json\n' >"$TD/.claude/settings.json"
BEFORE="$(sig "$TD/.claude/settings.json")"
run_install "$FI" "$TD" --pack alpha
expect_rc 'an unusable settings.json gives a conflict (exit 3)' 3
out_has 'the settings conflict is reported' 'CONFLICT settings'
[ "$(sig "$TD/.claude/settings.json")" = "$BEFORE" ] && ok 'the unusable settings.json is untouched' || fail 'the unusable settings.json is untouched'
pass_if 'pack files are still installed' test -f "$TD/.claude/agents/alpha/agent.md"
TE="$TMP/te"; mkdir -p "$TE/.claude"
printf '{"hooks":{"PreToolUse":{"not":"an array"}}}\n' >"$TE/.claude/settings.json"
BEFORE="$(sig "$TE/.claude/settings.json")"
run_install "$FI" "$TE" --pack alpha
expect_rc 'a settings.json with a wrong shape gives a conflict (exit 3)' 3
[ "$(sig "$TE/.claude/settings.json")" = "$BEFORE" ] && ok 'the wrong-shape settings.json is untouched' || fail 'the wrong-shape settings.json is untouched'

# A corrupt manifest stops everything.
TF="$TMP/tf"; mkdir -p "$TF/.claude"
printf 'garbage\n' >"$TF/.claude/packs.lock.json"
run_install "$FI" "$TF" --pack alpha
expect_rc 'a corrupt manifest exits 1' 1
pass_if 'nothing copied when the manifest is corrupt' test ! -e "$TF/.claude/agents"

# Invalid manifests.
for bad in badjson badname unsafe missingfile absolute; do mkpack "$bad"; done
printf '{not json\n' >"$F/packs/badjson/pack.json"
printf '{"name":"someone-else","files":[]}\n' >"$F/packs/badname/pack.json"
printf '{"name":"unsafe","files":["agents/../../escape.md"]}\n' >"$F/packs/unsafe/pack.json"
printf '{"name":"missingfile","files":["agents/not-there.md"]}\n' >"$F/packs/missingfile/pack.json"
printf '{"name":"absolute","files":["/etc/passwd"]}\n' >"$F/packs/absolute/pack.json"
TG="$TMP/tg"; mkdir -p "$TG"
for bad in badjson badname unsafe missingfile absolute; do
  run_install "$FI" "$TG" --pack "$bad"
  expect_rc "invalid manifest ($bad) exits 1" 1
done
pass_if 'invalid manifests leave the target untouched' test ! -e "$TG/.claude"

# Plugin symlinks that do not resolve fail the install.
rm "$F/plugin/agent-os-workflow/hooks"; ln -s ../../missing-dir "$F/plugin/agent-os-workflow/hooks"
TH="$TMP/th"; mkdir -p "$TH"
run_install "$FI" "$TH"
expect_rc 'dangling plugin links exit 1' 1
out_has 'the dangling link is named' 'hooks'

[ "$FAILS" -eq 0 ]

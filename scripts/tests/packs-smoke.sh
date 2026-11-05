#!/bin/bash
# packs-smoke.sh — every real pack under packs/ (Bash 3.2, no network).
#
# Usage: /bin/bash .claude/scripts/tests/packs-smoke.sh
# Per pack: pack.json is valid and README.md exists; --list-packs names it; a plain install ships none of its
#   payload; --pack installs every listed file byte-for-byte and wires its hooks and routing keys; a second run
#   changes nothing (settings.json and the manifest stay byte-identical); --remove-pack returns the target to the
#   plain-install tree, settings.json and routing.json. Then all packs together: install and remove in reverse.
# A pack whose `requires` names a command missing on this host is skipped, not failed. Exit 1 on any FAIL.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SRC="$(cd "$HERE/../.." && pwd -P)"
INSTALL="$SRC/install.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/packs-smoke.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed"; exit 1; }

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
# tree_sig <dir>: relative path and hash of every file, except the pack manifest and the two JSON files a pack
# merges into (they are compared as canonical JSON, since a merge rewrites their formatting).
tree_sig() {
  (cd "$1" && find . -type f ! -name packs.lock.json ! -path ./settings.json ! -path ./routing.json | sort | while IFS= read -r f; do echo "$f $(sha_of "$f")"; done)
}
canon() { jq -S -c . "$1"; }

PACKS=""
for m in "$SRC"/packs/*/pack.json; do
  [ -f "$m" ] && PACKS="$PACKS $(basename "$(dirname "$m")")"
done
if [ -z "$PACKS" ]; then ok "no packs in this tree"; exit 0; fi

# Run with HARNESS_SMOKE_PACKS the fixture already carries pack payloads in .claude/, so "a plain install ships
# none of it" cannot hold; the default run checks that.
for p in $PACKS; do
  f="$(jq -r '.files[0]' "$SRC/packs/$p/pack.json")"
  if [ -e "$SRC/$f" ]; then ok "skipped: pack payload is already in this tree (HARNESS_SMOKE_PACKS); run without it"; exit 0; fi
done

# ---- static checks -------------------------------------------------------------------------------------------
for p in $PACKS; do
  m="$SRC/packs/$p/pack.json"
  if jq -e --arg n "$p" '.name == $n and (.description | type == "string" and length > 0) and (.files | length > 0)' "$m" >/dev/null 2>&1; then
    ok "$p: pack.json names the pack, describes it and lists files"
  else fail "$p: pack.json name, description and files"; fi
  [ -s "$SRC/packs/$p/README.md" ] && ok "$p: README.md present" || fail "$p: README.md missing"
  missing=""
  while IFS= read -r f; do [ -f "$SRC/packs/$p/$f" ] || missing="$missing $f"; done < <(jq -r '.files[]' "$m")
  [ -z "$missing" ] && ok "$p: every listed file exists" || fail "$p: listed files missing" "$missing"
  if jq -e '(.files) as $fs | ((.prior_hashes // {}) | to_entries | all(.[]; (.key as $k | $fs | index($k) != null) and (.value | all(.[]; test("^[0-9a-f]{64}$")))))' "$m" >/dev/null 2>&1; then
    ok "$p: prior_hashes belong to listed files and are sha256 values"
  else fail "$p: prior_hashes"; fi
  stray=""
  for d in agents commands skills hooks scripts rules docs omp prompts templates; do
    [ -d "$SRC/packs/$p/$d" ] || continue
    while IFS= read -r f; do
      f="${f#"$SRC/packs/$p/"}"
      [ "$(basename "$f")" = .DS_Store ] && continue
      jq -e --arg f "$f" '.files | index($f) != null' "$m" >/dev/null 2>&1 || stray="$stray $f"
    done < <(find "$SRC/packs/$p/$d" -type f)
  done
  [ -z "$stray" ] && ok "$p: no payload file is missing from pack.json" || fail "$p: files on disk but not listed" "$stray"
done

LIST="$(/bin/bash "$INSTALL" --list-packs 2>&1)"
for p in $PACKS; do
  printf '%s\n' "$LIST" | grep -q "^$p	" && ok "$p: --list-packs names it" || fail "$p: --list-packs" "$LIST"
done

# ---- install / remove round trips ------------------------------------------------------------------------------
T="$TMP/target"; mkdir -p "$T"
OUT="$(/bin/bash "$INSTALL" "$T" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok 'plain install exits 0' || fail 'plain install' "rc=$RC: $OUT"
for p in $PACKS; do
  shipped=""
  while IFS= read -r f; do [ -e "$T/.claude/$f" ] && shipped="$shipped $f"; done < <(jq -r '.files[]' "$SRC/packs/$p/pack.json")
  [ -z "$shipped" ] && ok "$p: a plain install ships none of its payload" || fail "$p: payload in a plain install" "$shipped"
done
[ ! -e "$T/.claude/packs" ] && ok 'packs/ is not copied into the target' || fail 'packs/ copied into the target'
BASE_SIG="$TMP/base.sig"; tree_sig "$T/.claude" >"$BASE_SIG"
canon "$T/.claude/settings.json" >"$TMP/base.settings"
canon "$T/.claude/routing.json" >"$TMP/base.routing"

# deps_of <pack>: required packs, one per line.
deps_of() { jq -r '(.requires // [])[] | select(startswith("pack:")) | sub("^pack:"; "")' "$SRC/packs/$1/pack.json"; }
# usable <pack>: every cmd: / bare requirement is on PATH.
usable() {
  local r
  while IFS= read -r r; do
    case "$r" in pack:*) continue ;; esac
    command -v "${r#cmd:}" >/dev/null 2>&1 || return 1
  done < <(jq -r '(.requires // [])[]' "$SRC/packs/$1/pack.json")
  return 0
}

check_installed() { # <pack>
  local p="$1" f bad="" cmd ev key
  while IFS= read -r f; do
    if [ ! -f "$T/.claude/$f" ] || [ "$(sha_of "$T/.claude/$f")" != "$(sha_of "$SRC/packs/$p/$f")" ]; then bad="$bad $f"; fi
  done < <(jq -r '.files[]' "$SRC/packs/$p/pack.json")
  [ -z "$bad" ] && ok "$p: every file installed byte-for-byte" || fail "$p: installed files differ" "$bad"
  bad=""
  while IFS=$'\t' read -r ev cmd; do
    [ -n "$cmd" ] || continue
    jq -e --arg ev "$ev" --arg c "$cmd" '(.hooks[$ev] // []) | any(.[]; (.hooks // []) | any(.[]; .command == $c))' "$T/.claude/settings.json" >/dev/null 2>&1 || bad="$bad $cmd"
    [ -f "$T/.claude/${cmd#.claude/}" ] || bad="$bad(missing file:$cmd)"
  done < <(jq -r '(.hooks // [])[] | [.event, .command] | @tsv' "$SRC/packs/$p/pack.json")
  [ -z "$bad" ] && ok "$p: hooks wired in settings.json and their files exist" || fail "$p: hooks" "$bad"
  bad=""
  for key in $(jq -r '(.routing // {}) | keys[]' "$SRC/packs/$p/pack.json"); do
    jq -e --arg k "$key" 'has($k)' "$T/.claude/routing.json" >/dev/null 2>&1 || bad="$bad $key"
  done
  [ -z "$bad" ] && ok "$p: routing keys present" || fail "$p: routing keys" "$bad"
}

ORDER=""
for p in $PACKS; do
  usable "$p" || { ok "$p: skipped, a required command is missing on this host"; continue; }
  # dependencies first, one level deep is enough for the packs in this tree
  for d in $(deps_of "$p"); do case " $ORDER " in *" $d "*) ;; *) ORDER="$ORDER $d" ;; esac; done
  case " $ORDER " in *" $p "*) ;; *) ORDER="$ORDER $p" ;; esac
done

for p in $ORDER; do
  pre=""
  for d in $(deps_of "$p"); do pre="$pre --pack $d"; done
  # shellcheck disable=SC2086
  OUT="$(/bin/bash "$INSTALL" "$T" $pre --pack "$p" 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok "$p: --pack exits 0" || fail "$p: --pack" "rc=$RC: $OUT"
  check_installed "$p"
  cp "$T/.claude/settings.json" "$TMP/s1"; cp "$T/.claude/packs.lock.json" "$TMP/l1"
  # shellcheck disable=SC2086
  OUT="$(/bin/bash "$INSTALL" "$T" $pre --pack "$p" 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok "$p: a second --pack exits 0" || fail "$p: second --pack" "rc=$RC: $OUT"
  cmp -s "$TMP/s1" "$T/.claude/settings.json" && cmp -s "$TMP/l1" "$T/.claude/packs.lock.json" \
    && ok "$p: a second --pack leaves settings.json and the manifest byte-identical" || fail "$p: second --pack changed something"
  # remove dependents of $p first: none in this tree, but the installer refuses otherwise
  # shellcheck disable=SC2086
  OUT="$(/bin/bash "$INSTALL" "$T" --remove-pack "$p" 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok "$p: --remove-pack exits 0" || fail "$p: --remove-pack" "rc=$RC: $OUT"
  for d in $(deps_of "$p"); do
    OUT="$(/bin/bash "$INSTALL" "$T" --remove-pack "$d" 2>&1)" || fail "$p: removing dependency $d" "$OUT"
  done
  tree_sig "$T/.claude" >"$TMP/after.sig"
  cmp -s "$BASE_SIG" "$TMP/after.sig" && ok "$p: removal returns the tree to the plain install" \
    || fail "$p: tree differs after removal" "$(diff "$BASE_SIG" "$TMP/after.sig" | head -n 6)"
  [ "$(canon "$T/.claude/settings.json")" = "$(cat "$TMP/base.settings")" ] && ok "$p: settings.json restored" || fail "$p: settings.json not restored"
  [ "$(canon "$T/.claude/routing.json")" = "$(cat "$TMP/base.routing")" ] && ok "$p: routing.json restored" || fail "$p: routing.json not restored"
  [ "$(jq -c '.packs' "$T/.claude/packs.lock.json")" = '{}' ] && ok "$p: manifest empty after removal" || fail "$p: manifest not empty"
done

# All together: install every usable pack in one call, check, remove in reverse order.
ARGS=""; REV=""
for p in $ORDER; do ARGS="$ARGS --pack $p"; REV="$p $REV"; done
if [ -n "$ORDER" ]; then
  # shellcheck disable=SC2086
  OUT="$(/bin/bash "$INSTALL" "$T" $ARGS 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok 'all packs install in one call' || fail 'all packs install' "rc=$RC: $OUT"
  for p in $ORDER; do check_installed "$p"; done
  RM=""; for p in $REV; do RM="$RM --remove-pack $p"; done
  # shellcheck disable=SC2086
  OUT="$(/bin/bash "$INSTALL" "$T" $RM 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && ok 'all packs remove in one call' || fail 'all packs remove' "rc=$RC: $OUT"
  tree_sig "$T/.claude" >"$TMP/after.sig"
  cmp -s "$BASE_SIG" "$TMP/after.sig" && ok 'removing every pack returns the plain-install tree' || fail 'tree differs after removing every pack' "$(diff "$BASE_SIG" "$TMP/after.sig" | head -n 6)"
  [ "$(canon "$T/.claude/settings.json")" = "$(cat "$TMP/base.settings")" ] && ok 'settings.json restored after every pack' || fail 'settings.json not restored after every pack'
fi

[ "$FAILS" -eq 0 ]

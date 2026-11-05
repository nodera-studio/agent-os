#!/usr/bin/env bash
# install.sh — drop the agent-os harness into a target project's .claude/ directory, and manage optional packs.
#
# Usage: ./install.sh <target-project-path> [--pack NAME]...
#        ./install.sh <target-project-path> --remove-pack NAME [--remove-pack NAME]...
#        ./install.sh --list-packs [<target-project-path>]
#
# Copies this repo's agents/, commands/, skills/, hooks/, rules/, docs/, scripts/,
# prompts/, plugin/, omp/, templates/, the scaffold dirs (plans/, research/, tech-debt/, testing/,
# evidence/, handoffs/), settings.json, routing.json (if absent) and
# CLAUDE.md.template into <target>/.claude/. Never overwrites an existing <target>/.claude/settings.json
# or <target>/.claude/CLAUDE.md — those are skipped with a warning if present, so
# a re-run never clobbers project-specific customization. Nothing is ever deleted by a plain install
# (no rsync --delete).
#
# Packs: optional bundles under packs/<name>/ (schema in packs/README.md). --pack copies the pack's files,
# records each with its sha256 in <target>/.claude/packs.lock.json, merges the pack's hook entries into
# settings.json (deduped by command) and its routing fragment into routing.json (unset keys only).
# Re-running --pack upgrades files that are unchanged since install. --remove-pack deletes only files whose
# current hash equals the recorded one. A modified file, or one that is not in the manifest and matches no known
# prior hash of the pack (ambiguous ownership), is kept and reported as a CONFLICT. A --pack run does the plain
# install first; --remove-pack and --list-packs do not.
# Needs jq (and sha256sum or shasum). INSTALL_NO_RSYNC=1 forces the cp fallback (the smoke test uses it).
# Exit: 0 ok, 1 error or bad usage, 3 finished but with conflicts.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKS_DIR="$SOURCE_DIR/packs"

die() { echo "install.sh: $*" >&2; exit 1; }
usage() {
  cat >&2 <<'USAGE'
Usage: install.sh <target-project-path> [--pack NAME]...
       install.sh <target-project-path> --remove-pack NAME [--remove-pack NAME]...
       install.sh --list-packs [<target-project-path>]
USAGE
  exit 1
}

TARGET_PROJECT=""
PACK_ARGS=""
REMOVE_ARGS=""
LIST_PACKS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pack) [ $# -ge 2 ] || die "--pack needs a name"; PACK_ARGS="$PACK_ARGS $2"; shift ;;
    --remove-pack) [ $# -ge 2 ] || die "--remove-pack needs a name"; REMOVE_ARGS="$REMOVE_ARGS $2"; shift ;;
    --list-packs) LIST_PACKS=1 ;;
    -h|--help) usage ;;
    -*) echo "install.sh: unknown option: $1" >&2; usage ;;
    *) [ -z "$TARGET_PROJECT" ] || usage; TARGET_PROJECT="$1" ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die "jq is required (install it, e.g. 'brew install jq' or 'apt-get install jq')"
if command -v sha256sum >/dev/null 2>&1; then
  file_sha() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  file_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die "sha256sum or shasum is required"
fi

for n in $PACK_ARGS $REMOVE_ARGS; do
  case "$n" in
    ''|-*|*[!a-z0-9_-]*) die "invalid pack name: $n (lower-case letters, digits, - and _ only)" ;;
  esac
done
for n in $PACK_ARGS; do
  case " $REMOVE_ARGS " in *" $n "*) die "pack $n is both installed and removed in one call" ;; esac
done

if [ "$LIST_PACKS" = 0 ] && [ -z "$TARGET_PROJECT" ]; then usage; fi
if [ -n "$TARGET_PROJECT" ] && [ ! -d "$TARGET_PROJECT" ]; then
  die "target path does not exist or is not a directory: $TARGET_PROJECT"
fi

TARGET_CLAUDE=""
LOCK=""
if [ -n "$TARGET_PROJECT" ]; then
  TARGET_CLAUDE="$TARGET_PROJECT/.claude"
  LOCK="$TARGET_CLAUDE/packs.lock.json"
fi
CONFLICTS=0
CLEANUP=""
cleanup() { local f; for f in $CLEANUP; do rm -rf "$f"; done; }
trap cleanup EXIT
conflict() { CONFLICTS=$((CONFLICTS + 1)); echo "install.sh: CONFLICT $*"; }

# ---------------------------------------------------------------------------------------------------------
# Lock file, atomic writes
# ---------------------------------------------------------------------------------------------------------
lock_read() {
  if [ -f "$LOCK" ]; then cat "$LOCK"; else echo '{"version":1,"packs":{}}'; fi
}
lock_check() {
  lock_read | jq -e '(.version == 1) and (.packs | type == "object")' >/dev/null 2>&1 \
    || die "$LOCK is not a valid pack manifest; fix or delete it"
}
# write_atomic <dest>: stdin to a temp file next to <dest> (mode copied from it), validated as JSON, then mv.
write_atomic() {
  local dest="$1" tmp
  tmp="$(mktemp "$dest.XXXXXX")" || die "cannot write next to $dest"
  if [ -f "$dest" ]; then cp -p "$dest" "$tmp"; else chmod 644 "$tmp"; fi
  cat >"$tmp"
  if ! jq -e . "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; die "refusing to write invalid JSON to $dest"; fi
  mv "$tmp" "$dest"
}
# json_same <file> <json-text>: true when the file already holds the same JSON value.
json_same() {
  [ -f "$1" ] || return 1
  [ "$(jq -S -c . "$1" 2>/dev/null)" = "$(printf '%s' "$2" | jq -S -c . 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------------------------------------
# Pack manifests
# ---------------------------------------------------------------------------------------------------------
# safe_rel <rel>: a relative path under one of the harness directories a pack may populate.
safe_rel() {
  case "$1" in ''|/*) return 1 ;; esac
  case "/$1/" in */../*|*/./*|*//*) return 1 ;; esac
  case "$1" in */*) ;; *) return 1 ;; esac
  case "${1%%/*}" in agents|commands|skills|hooks|scripts|rules|docs|omp|prompts|templates) return 0 ;; esac
  return 1
}
pack_manifest() { echo "$PACKS_DIR/$1/pack.json"; }

# pack_validate <name> <prior-names-in-this-call>: manifest sane, files present, dependencies satisfied.
pack_validate() {
  local name="$1" prior="$2" m rel req
  m="$(pack_manifest "$name")"
  [ -f "$m" ] || die "unknown pack: $name (no $m)"
  jq -e --arg n "$name" '
    (.name == $n) and (.files | type == "array") and (.files | all(.[]; type == "string"))
    and ((.hooks // []) | type == "array")
    and ((.hooks // []) | all(.[]; (.event | type == "string") and (.command | type == "string")
         and (.event | length > 0) and (.command | length > 0)))
    and ((.requires // []) | type == "array") and ((.requires // []) | all(.[]; type == "string"))
    and ((.routing // {}) | type == "object")
    and ((.prior_hashes // {}) | type == "object")' "$m" >/dev/null 2>&1 \
    || die "pack $name: $m is not a valid pack manifest (see packs/README.md)"
  while IFS= read -r rel; do
    safe_rel "$rel" || die "pack $name: unsafe or unsupported file path: $rel"
    [ -f "$PACKS_DIR/$name/$rel" ] && [ ! -L "$PACKS_DIR/$name/$rel" ] || die "pack $name: listed file is missing: $rel"
  done < <(jq -r '.files[]' "$m")
  while IFS= read -r req; do
    [ -n "$req" ] || continue
    case "$req" in
      pack:*)
        if [ -n "$LOCK" ] && lock_read | jq -e --arg n "${req#pack:}" '.packs[$n] != null' >/dev/null 2>&1; then continue; fi
        case " $prior " in *" ${req#pack:} "*) continue ;; esac
        die "pack $name requires pack ${req#pack:}, which is not installed; install it first (--pack ${req#pack:})"
        ;;
      *)
        command -v "${req#cmd:}" >/dev/null 2>&1 || die "pack $name requires '${req#cmd:}', which is not on PATH"
        ;;
    esac
  done < <(jq -r '(.requires // [])[]' "$m")
}

# ---------------------------------------------------------------------------------------------------------
# --list-packs
# ---------------------------------------------------------------------------------------------------------
list_packs() {
  local m name desc state found=0
  [ -n "$LOCK" ] && lock_check
  for m in "$PACKS_DIR"/*/pack.json; do
    [ -f "$m" ] || continue
    found=1
    name="$(jq -r '.name // empty' "$m")"
    [ -n "$name" ] || name="$(basename "$(dirname "$m")")"
    desc="$(jq -r '.description // ""' "$m")"
    state="-"
    if [ -n "$LOCK" ]; then
      state="not installed"
      if lock_read | jq -e --arg n "$name" '.packs[$n] != null' >/dev/null 2>&1; then
        state="installed"
        if lock_read | jq -e --arg n "$name" '.packs[$n].partial == true' >/dev/null 2>&1; then state="partly removed"; fi
      fi
    fi
    printf '%s\t%s\t%s\n' "$name" "$state" "$desc"
  done
  [ "$found" = 1 ] || echo "install.sh: no packs available (no packs/*/pack.json)"
}

# ---------------------------------------------------------------------------------------------------------
# Plain install
# ---------------------------------------------------------------------------------------------------------
# Directories copied wholesale (safe to overwrite — this harness owns them). Nothing in them is deleted.
DIRS=(agents commands skills hooks rules docs scripts prompts plugin omp templates plans research tech-debt testing evidence handoffs)

copy_dir() {
  local name="$1"
  local src="$SOURCE_DIR/$name"
  local dest="$TARGET_CLAUDE/$name"
  [ -d "$src" ] || return 0
  mkdir -p "$dest"
  if [ "${INSTALL_NO_RSYNC:-0}" != 1 ] && command -v rsync >/dev/null 2>&1; then
    rsync -a "$src/" "$dest/"
  else
    cp -R "$src/." "$dest/"
  fi
  echo "install.sh: synced $name/"
}

# Project-owned files: seed once, never overwrite (routing.json carries the project's engine
# routing override). The orchestrator pack's gap log is not seeded: the pack's recorder creates it on first use.
seed_once() {
  local rel="$1"
  [ -f "$SOURCE_DIR/$rel" ] || return 0
  if [ -f "$TARGET_CLAUDE/$rel" ]; then
    echo "install.sh: $rel already exists, skipping (not overwritten)"
  else
    mkdir -p "$(dirname "$TARGET_CLAUDE/$rel")"
    cp "$SOURCE_DIR/$rel" "$TARGET_CLAUDE/$rel"
    echo "install.sh: wrote $rel"
  fi
}

base_install() {
  mkdir -p "$TARGET_CLAUDE"
  local d
  for d in "${DIRS[@]}"; do
    copy_dir "$d"
  done

  seed_once routing.json

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

  # The plugin directory is symlinks (../../agents etc.); they must resolve in the target, not dangle.
  if [ -d "$TARGET_CLAUDE/plugin/agent-os-workflow" ]; then
    local bad="" c
    for c in agents commands hooks skills; do
      [ -d "$TARGET_CLAUDE/plugin/agent-os-workflow/$c/" ] || bad="$bad $c"
    done
    [ -z "$bad" ] || die "plugin/agent-os-workflow links do not resolve in the target:$bad"
  fi
}

# ---------------------------------------------------------------------------------------------------------
# Pack install / upgrade
# ---------------------------------------------------------------------------------------------------------
SETTINGS=""
ROUTING=""
settings_usable() {
  [ -f "$SETTINGS" ] && jq -e '
    (type == "object") and ((.hooks // {}) | type == "object")
    and ((.hooks // {}) | to_entries | all(.[]; (.value | type == "array")
         and (.value | all(.[]; type == "object" and ((.hooks // []) | type == "array")))))' "$SETTINGS" >/dev/null 2>&1
}
# settings_update <jq-args...>: apply a jq program to settings.json; write only when the content changes.
settings_update() {
  local out
  out="$(jq "$@" "$SETTINGS")" || return 1
  if json_same "$SETTINGS" "$out"; then return 0; fi
  printf '%s\n' "$out" | write_atomic "$SETTINGS"
}

# prune_empty_dirs <rel>: remove directories a deleted file leaves empty (never a top-level one).
prune_empty_dirs() {
  local dir
  dir="$(dirname "$TARGET_CLAUDE/$1")"
  while [ "$dir" != "$TARGET_CLAUDE" ] && [ "$(dirname "$dir")" != "$TARGET_CLAUDE" ]; do
    rmdir "$dir" 2>/dev/null || break
    dir="$(dirname "$dir")"
  done
}

install_pack() {
  local name="$1" pdir m tmp rel src dest ssha dsha lsha newtsv hooks_json routing_json entry
  pdir="$PACKS_DIR/$name"
  m="$(pack_manifest "$name")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/install-pack.XXXXXX")"
  CLEANUP="$CLEANUP $tmp"
  newtsv="$tmp/files.tsv"
  : >"$newtsv"
  echo "install.sh: pack $name"

  while IFS= read -r rel; do
    src="$pdir/$rel"
    dest="$TARGET_CLAUDE/$rel"
    ssha="$(file_sha "$src")"
    lsha="$(lock_read | jq -r --arg n "$name" --arg p "$rel" '.packs[$n].files[$p] // empty')"
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
      mkdir -p "$(dirname "$dest")"
      cp -p "$src" "$dest"
      printf '%s\t%s\n' "$rel" "$ssha" >>"$newtsv"
      echo "install.sh:   installed $rel"
    elif [ -L "$dest" ] || [ ! -f "$dest" ]; then
      conflict "unmanaged $rel — the target exists and is not a regular file; left alone"
      [ -z "$lsha" ] || printf '%s\t%s\n' "$rel" "$lsha" >>"$newtsv"
    else
      dsha="$(file_sha "$dest")"
      if [ -n "$lsha" ]; then
        if [ "$dsha" = "$lsha" ]; then
          if [ "$ssha" = "$dsha" ]; then
            printf '%s\t%s\n' "$rel" "$ssha" >>"$newtsv"
          else
            cp -p "$src" "$dest"
            printf '%s\t%s\n' "$rel" "$ssha" >>"$newtsv"
            echo "install.sh:   updated $rel"
          fi
        elif [ "$dsha" = "$ssha" ]; then
          printf '%s\t%s\n' "$rel" "$ssha" >>"$newtsv"
          echo "install.sh:   adopted $rel (edited to match the pack)"
        else
          printf '%s\t%s\n' "$rel" "$lsha" >>"$newtsv"
          conflict "modified $rel — changed since install; kept, not upgraded"
        fi
      elif [ "$dsha" = "$ssha" ]; then
        printf '%s\t%s\n' "$rel" "$ssha" >>"$newtsv"
        echo "install.sh:   adopted $rel (identical to the pack file)"
      elif jq -e --arg p "$rel" --arg h "$dsha" '(.prior_hashes[$p] // []) | index($h) != null' "$m" >/dev/null 2>&1; then
        cp -p "$src" "$dest"
        printf '%s\t%s\n' "$rel" "$ssha" >>"$newtsv"
        echo "install.sh:   replaced $rel (a known earlier version)"
      else
        conflict "ambiguous-ownership $rel — exists, is not in the manifest and matches no known earlier version; kept"
      fi
    fi
  done < <(jq -r '.files[]' "$m")

  # Files the previous version of this pack shipped and this one does not.
  while IFS=$'\t' read -r rel lsha; do
    [ -n "$rel" ] || continue
    jq -e --arg p "$rel" '.files | index($p) != null' "$m" >/dev/null 2>&1 && continue
    dest="$TARGET_CLAUDE/$rel"
    if [ ! -e "$dest" ]; then continue; fi
    if [ -f "$dest" ] && [ ! -L "$dest" ] && [ "$(file_sha "$dest")" = "$lsha" ]; then
      rm -f "$dest"
      prune_empty_dirs "$rel"
      echo "install.sh:   removed $rel (no longer in the pack)"
    else
      conflict "modified $rel — no longer in the pack but changed since install; kept, now unmanaged"
    fi
  done < <(lock_read | jq -r --arg n "$name" '(.packs[$n].files // {}) | to_entries[] | [.key, .value] | @tsv')

  # Hooks: merge into settings.json, deduped by command.
  hooks_json="$tmp/hooks.json"
  echo '[]' >"$hooks_json"
  local hook ev matcher cmd timeout present prev added
  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    ev="$(printf '%s' "$hook" | jq -r '.event')"
    cmd="$(printf '%s' "$hook" | jq -r '.command')"
    matcher="$(printf '%s' "$hook" | jq -c '.matcher // null')"
    timeout="$(printf '%s' "$hook" | jq -c '.timeout // null')"
    if ! settings_usable; then
      conflict "settings $cmd — $SETTINGS is missing or has an unexpected shape; hook not wired"
      continue
    fi
    present=0
    jq -e --arg ev "$ev" --arg c "$cmd" '(.hooks[$ev] // []) | any(.[]; (.hooks // []) | any(.[]; .command == $c))' \
      "$SETTINGS" >/dev/null 2>&1 && present=1
    prev=false
    lock_read | jq -e --arg n "$name" --arg ev "$ev" --arg c "$cmd" \
      '(.packs[$n].hooks // []) | any(.[]; .event == $ev and .command == $c and .added == true)' >/dev/null 2>&1 && prev=true
    if [ "$present" = 1 ]; then
      added="$prev"
    else
      settings_update --arg ev "$ev" --arg c "$cmd" --argjson m "$matcher" --argjson t "$timeout" '
        ({type: "command", command: $c} + (if $t != null then {timeout: $t} else {} end)) as $entry
        | (.hooks[$ev] // []) as $arr
        | ($arr | map((.matcher // null) == $m) | index(true)) as $i
        | if $i != null then .hooks[$ev][$i].hooks = ((.hooks[$ev][$i].hooks // []) + [$entry])
          else .hooks[$ev] = $arr + [(if $m != null then {matcher: $m} else {} end) + {hooks: [$entry]}] end' \
        || die "could not merge hook $cmd into $SETTINGS"
      added=true
      echo "install.sh:   wired hook $cmd ($ev)"
    fi
    jq --arg ev "$ev" --arg c "$cmd" --argjson m "$matcher" --argjson a "$added" \
      '. + [{event: $ev, matcher: $m, command: $c, added: $a}]' "$hooks_json" >"$hooks_json.new" && mv "$hooks_json.new" "$hooks_json"
  done < <(jq -c '(.hooks // [])[]' "$m")

  # Hooks the previous version wired and this one does not.
  while IFS=$'\t' read -r ev cmd; do
    [ -n "$ev" ] || continue
    jq -e --arg ev "$ev" --arg c "$cmd" '(.hooks // []) | any(.[]; .event == $ev and .command == $c)' "$m" >/dev/null 2>&1 && continue
    unwire_hook "$ev" "$cmd"
  done < <(lock_read | jq -r --arg n "$name" '(.packs[$n].hooks // [])[] | select(.added == true) | [.event, .command] | @tsv')

  # Routing fragment: top-level keys that are unset in routing.json.
  routing_json="$tmp/routing.json"
  lock_read | jq -c --arg n "$name" '.packs[$n].routing // {}' >"$routing_json"
  local key val cur
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    val="$(jq -c --arg k "$key" '.routing[$k]' "$m")"
    if [ ! -f "$ROUTING" ] || ! jq -e 'type == "object"' "$ROUTING" >/dev/null 2>&1; then
      conflict "routing $key — $ROUTING is missing or not a JSON object; fragment not merged"
      continue
    fi
    if jq -e --arg k "$key" 'has($k)' "$ROUTING" >/dev/null 2>&1; then
      cur="$(jq -c --arg k "$key" '.[$k]' "$ROUTING")"
      if [ "$cur" = "$val" ] && jq -e --arg k "$key" 'has($k)' "$routing_json" >/dev/null 2>&1; then
        :
      else
        jq --arg k "$key" 'del(.[$k])' "$routing_json" >"$routing_json.new" && mv "$routing_json.new" "$routing_json"
        echo "install.sh:   routing key $key is already set; kept"
      fi
    else
      jq --arg k "$key" --argjson v "$val" '. + {($k): $v}' "$ROUTING" | write_atomic "$ROUTING"
      jq --arg k "$key" --argjson v "$val" '. + {($k): $v}' "$routing_json" >"$routing_json.new" && mv "$routing_json.new" "$routing_json"
      echo "install.sh:   routing key $key set"
    fi
  done < <(jq -r '(.routing // {}) | keys[]' "$m")

  # Record the pack.
  entry="$(jq -n --slurpfile mf "$m" --slurpfile hk "$hooks_json" --slurpfile rt "$routing_json" \
    --argjson files "$(jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}' <"$newtsv")" \
    '{version: ($mf[0].version // null), requires: ($mf[0].requires // []), files: $files, hooks: $hk[0], routing: $rt[0]}')"
  lock_read | jq -S --arg n "$name" --argjson e "$entry" '.packs[$n] = $e' | write_atomic "$LOCK"
  rm -rf "$tmp"
}

# unwire_hook <event> <command>: remove that command from settings.json and drop groups it leaves empty.
unwire_hook() {
  if ! settings_usable; then
    conflict "settings $2 — $SETTINGS is missing or has an unexpected shape; hook left in place"
    return 0
  fi
  settings_update --arg ev "$1" --arg c "$2" '
    if (.hooks[$ev] | type) == "array" then
      .hooks[$ev] |= (map(if ((.hooks // []) | any(.command == $c)) then (.hooks |= map(select(.command != $c))) else . end)
                      | map(select(((.hooks // [1]) | length) > 0)))
      | if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end
    else . end' || die "could not edit $SETTINGS"
  echo "install.sh:   unwired hook $2 ($1)"
}

# ---------------------------------------------------------------------------------------------------------
# Pack removal
# ---------------------------------------------------------------------------------------------------------
remove_pack() {
  local name="$1" rel lsha dest ev cmd key val cur kept dep
  lock_read | jq -e --arg n "$name" '.packs[$n] != null' >/dev/null 2>&1 || die "pack $name is not installed"
  dep="$(lock_read | jq -r --arg n "$name" --arg r "pack:$name" \
    '.packs | to_entries[] | select(.key != $n and ((.value.requires // []) | index($r) != null)) | .key' | head -n 1)"
  [ -z "$dep" ] || die "pack $name is required by installed pack $dep; remove $dep first"
  echo "install.sh: removing pack $name"
  kept="$(mktemp "${TMPDIR:-/tmp}/install-kept.XXXXXX")"
  CLEANUP="$CLEANUP $kept"

  while IFS=$'\t' read -r rel lsha; do
    [ -n "$rel" ] || continue
    dest="$TARGET_CLAUDE/$rel"
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
      echo "install.sh:   $rel already gone"
    elif [ -f "$dest" ] && [ ! -L "$dest" ] && [ "$(file_sha "$dest")" = "$lsha" ]; then
      rm -f "$dest"
      prune_empty_dirs "$rel"
      echo "install.sh:   removed $rel"
    else
      conflict "modified $rel — changed since install; kept"
      printf '%s\t%s\n' "$rel" "$lsha" >>"$kept"
    fi
  done < <(lock_read | jq -r --arg n "$name" '(.packs[$n].files // {}) | to_entries[] | [.key, .value] | @tsv')

  while IFS=$'\t' read -r ev cmd; do
    [ -n "$ev" ] || continue
    unwire_hook "$ev" "$cmd"
  done < <(lock_read | jq -r --arg n "$name" '(.packs[$n].hooks // [])[] | select(.added == true) | [.event, .command] | @tsv')

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    val="$(lock_read | jq -c --arg n "$name" --arg k "$key" '.packs[$n].routing[$k]')"
    cur="$(jq -c --arg k "$key" '.[$k] // "__unset__"' "$ROUTING" 2>/dev/null || echo '"__unset__"')"
    if [ "$cur" = '"__unset__"' ]; then
      :
    elif [ "$cur" = "$val" ]; then
      jq --arg k "$key" 'del(.[$k])' "$ROUTING" | write_atomic "$ROUTING"
      echo "install.sh:   removed routing key $key"
    else
      conflict "routing $key — changed since install; kept"
    fi
  done < <(lock_read | jq -r --arg n "$name" '(.packs[$n].routing // {}) | keys[]')

  if [ -s "$kept" ]; then
    lock_read | jq -S --arg n "$name" --argjson files "$(jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}' <"$kept")" \
      '.packs[$n] |= (.files = $files | .hooks = [] | .routing = {} | .partial = true)' | write_atomic "$LOCK"
    echo "install.sh: pack $name partly removed; resolve the conflicts and run --remove-pack $name again"
  else
    lock_read | jq -S --arg n "$name" 'del(.packs[$n])' | write_atomic "$LOCK"
  fi
  rm -f "$kept"
}

# ---------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------
if [ "$LIST_PACKS" = 1 ]; then
  list_packs
  exit 0
fi

[ -z "$PACK_ARGS$REMOVE_ARGS" ] || lock_check
SETTINGS="$TARGET_CLAUDE/settings.json"
ROUTING="$TARGET_CLAUDE/routing.json"

# Validate every requested pack before anything is copied.
seen=""
for n in $PACK_ARGS; do
  pack_validate "$n" "$seen"
  seen="$seen $n"
done

if [ -n "$REMOVE_ARGS" ] && [ -z "$PACK_ARGS" ]; then
  [ -d "$TARGET_CLAUDE" ] || die "$TARGET_CLAUDE does not exist; nothing to remove"
else
  base_install
fi

for n in $PACK_ARGS; do
  install_pack "$n"
done
for n in $REMOVE_ARGS; do
  remove_pack "$n"
done

echo ""
if [ "$CONFLICTS" -gt 0 ]; then
  echo "install.sh: done with $CONFLICTS conflict(s); the files above were left as they are."
  exit 3
fi
if [ -z "$REMOVE_ARGS" ] || [ -n "$PACK_ARGS" ]; then
  echo "install.sh: done. Now run /bootstrap-project inside Claude Code in the target project to customize it."
else
  echo "install.sh: done."
fi

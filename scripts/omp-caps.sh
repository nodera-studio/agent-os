#!/usr/bin/env bash
# omp-caps.sh — which omp engine slots are capped until when, plus dispatch counters for budgets.
#
# Usage: omp-caps.sh mark <engine> <slot> <model> <until-iso|+N[smhd]> <signal>   (signal: 429|402|usage|budget)
#        omp-caps.sh clear <engine> <slot> <model>
#        omp-caps.sh status [<engine> <slot> <model>]   (with a key: exit 0 = capped, 1 = not)
#        omp-caps.sh expire                             drop entries whose time has passed
#        omp-caps.sh count <engine> <slot> <model> [usd]  one dispatch; caps the slot when its budget is spent
# State: <dir>/omp-caps.json  { "<engine>/<slot>/<model>": {"until":"<iso>","signal":"…"} }, read by
# `routing.sh engines`, and <dir>/omp-counts.json for the counters. <dir> is $HARNESS_ROUTING_DIR/state, else
# <main checkout>/.claude/state (git-ignored runtime state, shared by every worktree). Expired entries are
# ignored on every read, never trusted. A budget is the slot's `budget` in routing.json ({window_hours, max_calls,
# max_usd}); null is unlimited, and a non-null max with a null window counts over 24 hours. Needs jq.
set -u

die() { echo "omp-caps: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)" || die "cannot resolve the script directory"
if [ -n "${HARNESS_ROUTING_DIR:-}" ]; then
  CLAUDE_DIR="$HARNESS_ROUTING_DIR"
else
  COMMON="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || die "not inside a git checkout: $SCRIPT_DIR"
  CLAUDE_DIR="$(cd "$COMMON/.." && pwd -P)/.claude"
fi
STATE="$CLAUDE_DIR/state"
CAPS="$STATE/omp-caps.json"
COUNTS="$STATE/omp-counts.json"
LOCK="$STATE/.lock"

iso_now() { jq -nr 'now | todate'; }

# with_lock: take the state lock (mkdir is atomic), waiting up to 5 s; a lock whose pid is gone is taken over.
HELD=0
take_lock() {
  local i=0 pid
  mkdir -p "$STATE" || die "cannot create $STATE"
  while ! mkdir "$LOCK" 2>/dev/null; do
    pid="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    i=$((i + 1))
    [ "$i" -le 50 ] || die "state lock busy: $LOCK"
    sleep 0.1
  done
  HELD=1
  echo "$$" > "$LOCK/pid"
}
drop_lock() { [ "$HELD" -eq 0 ] || rm -rf "$LOCK"; HELD=0; }
trap drop_lock EXIT

# read_json <file>: the document, {} when absent; status 1 if it is not a JSON object. Callers run it in a
# command substitution, where die could not stop the script, so they exit on the status themselves.
read_json() {
  [ -e "$1" ] || { echo '{}'; return 0; }
  jq -ce 'if type == "object" then . else error("not an object") end' "$1" 2>/dev/null || { echo "omp-caps: broken JSON in $1" >&2; return 1; }
}
# live_doc <file>: the file's document without expired entries.
live_doc() {
  local doc
  doc="$(read_json "$1")" || exit 2
  live "$doc"
}
# write_json <file> <json>: temp file in the same directory, validated, then mv.
write_json() {
  local tmp
  tmp="$(mktemp "$STATE/.tmp.XXXXXX")" || die "cannot write in $STATE"
  printf '%s\n' "$2" | jq -e . > "$tmp" 2>/dev/null || { rm -f "$tmp"; die "refusing to write invalid JSON to $1"; }
  mv "$tmp" "$1"
}
# live <json>: the object without its expired entries.
live() { printf '%s' "$1" | jq -c --arg n "$(iso_now)" 'with_entries(select(.value.until > $n))'; }

valid_key() {
  [[ "$1" =~ ^omp:[a-z0-9-]+$ ]] || die "bad engine id: $1"
  [[ "$2" =~ ^[a-z0-9_-]+$ ]] || die "bad slot: $2"
  [[ "$3" =~ ^[A-Za-z0-9._:-]+$ ]] || die "bad model id: $3"
}
# until_iso <arg>: an ISO UTC time from YYYY-MM-DDTHH:MM:SSZ or +N[smhd].
until_iso() {
  local n unit secs
  if [[ "$1" =~ ^\+([0-9]+)([smhd])$ ]]; then
    n="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    case "$unit" in s) secs=$n ;; m) secs=$((n * 60)) ;; h) secs=$((n * 3600)) ;; d) secs=$((n * 86400)) ;; esac
    jq -nr --argjson s "$secs" 'now + $s | todate'
  elif [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && jq -en --arg t "$1" '$t | fromdateiso8601' >/dev/null 2>&1; then
    printf '%s\n' "$1"
  else
    die "bad time (want YYYY-MM-DDTHH:MM:SSZ or +N[smhd]): $1"
  fi
}

do_mark() {
  local key="$1/$2/$3" until="$4" signal="$5" doc
  case "$signal" in 429 | 402 | usage | budget) ;; *) die "bad signal: $signal" ;; esac
  take_lock
  doc="$(live_doc "$CAPS")" || exit 2
  write_json "$CAPS" "$(printf '%s' "$doc" | jq -c --arg k "$key" --arg u "$until" --arg s "$signal" '.[$k] = {until:$u,signal:$s}')"
  echo "capped $key until $until ($signal)"
}

# budget_of <engine> <slot>: the slot's budget object from routing.json, the override's engine entry first.
budget_of() {
  local f out
  for f in "$CLAUDE_DIR/auto-mode/routing.json" "$CLAUDE_DIR/routing.json" "$SCRIPT_DIR/../routing.json"; do
    [ -r "$f" ] || continue
    out="$(jq -c --arg e "$1" --arg s "$2" '.omp_engines[$e] // empty | .slots[] | select(.slot == $s) | .budget // {}' "$f" 2>/dev/null)"
    [ -z "$out" ] || { printf '%s\n' "$out"; return 0; }
  done
  echo '{}'
}

do_count() {
  local key="$1/$2/$3" slotkey="$1/$2" usd="${4:-0}" budget counts now window_h reset until spent
  [[ "$usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "bad usd: $usd"
  budget="$(budget_of "$1" "$2")"
  take_lock
  now="$(jq -nr 'now | floor')"
  window_h="$(printf '%s' "$budget" | jq -r '.window_hours // 24')"
  counts="$(read_json "$COUNTS")" || exit 2
  counts="$(printf '%s' "$counts" | jq -c --arg k "$slotkey" --argjson now "$now" --argjson w "$window_h" --argjson usd "$usd" '
    (.[$k] // {start:$now,calls:0,usd:0}) as $c
    | (if $now - $c.start >= $w * 3600 then {start:$now,calls:0,usd:0} else $c end) as $c
    | .[$k] = {start:$c.start,calls:($c.calls + 1),usd:($c.usd + $usd)}')"
  write_json "$COUNTS" "$counts"
  spent="$(printf '%s' "$counts" | jq -c --arg k "$slotkey" --argjson b "$budget" '
    .[$k] as $c | ((($b.max_calls // null) != null and $c.calls > $b.max_calls)
      or (($b.max_usd // null) != null and $c.usd > $b.max_usd))')"
  if [ "$spent" = true ]; then
    reset="$(printf '%s' "$counts" | jq -r --arg k "$slotkey" --argjson w "$window_h" '.[$k].start + ($w * 3600) | todate')"
    until="$reset"
    drop_lock
    do_mark "$1" "$2" "$3" "$until" budget
  else
    echo "counted $key"
  fi
}

case "${1:-}" in
  mark)
    [ $# -eq 6 ] || die "usage: omp-caps.sh mark <engine> <slot> <model> <until> <signal>"
    valid_key "$2" "$3" "$4"
    until="$(until_iso "$5")" || exit 2
    do_mark "$2" "$3" "$4" "$until" "$6"
    ;;
  clear)
    [ $# -eq 4 ] || die "usage: omp-caps.sh clear <engine> <slot> <model>"
    valid_key "$2" "$3" "$4"
    take_lock
    doc="$(live_doc "$CAPS")" || exit 2
    write_json "$CAPS" "$(printf '%s' "$doc" | jq -c --arg k "$2/$3/$4" 'del(.[$k])')"
    echo "cleared $2/$3/$4"
    ;;
  status)
    doc="$(live_doc "$CAPS")" || exit 2
    if [ $# -eq 4 ]; then
      valid_key "$2" "$3" "$4"
      line="$(printf '%s' "$doc" | jq -r --arg k "$2/$3/$4" '.[$k] // empty | "capped until \(.until) (\(.signal))"')"
      if [ -n "$line" ]; then echo "$line"; exit 0; fi
      echo "not capped"
      exit 1
    fi
    [ $# -eq 1 ] || die "usage: omp-caps.sh status [<engine> <slot> <model>]"
    printf '%s' "$doc" | jq -r 'to_entries[] | "\(.key) until \(.value.until) (\(.value.signal))"'
    ;;
  expire)
    take_lock
    if [ -e "$CAPS" ]; then doc="$(live_doc "$CAPS")" || exit 2; write_json "$CAPS" "$doc"; fi
    echo expired
    ;;
  count)
    [ $# -ge 4 ] && [ $# -le 5 ] || die "usage: omp-caps.sh count <engine> <slot> <model> [usd]"
    valid_key "$2" "$3" "$4"
    do_count "$2" "$3" "$4" "${5:-0}"
    ;;
  *) die "usage: omp-caps.sh mark|clear|status|expire|count (see the header)" ;;
esac

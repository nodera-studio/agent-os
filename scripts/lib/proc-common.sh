# proc-common.sh — process and path helpers shared by remove-worktree.sh, clean-scratch.sh and
# codex-procs.sh. Source it; it defines functions only.
# shellcheck shell=bash
#
# Ownership is decided from ONE process snapshot (snapshot_procs: `ps -axww -o pid=,lstart=,command=`
# into $SNAP). Before each signal the pid's current pid/lstart/command must equal its snapshot line,
# else it is skipped (valid, stop_set).

# Field separator for every record: ASCII unit separator (a tab would collapse empty fields in read).
SEP=$'\x1f'

# canon PATH: canonical absolute path (pwd -P of the longest existing ancestor, plus the rest).
# Fails for a relative path or a non-existing remainder containing . or .. segments.
canon() {
  local p="${1%/}" rest=""
  case "$1" in /*) ;; *) return 1 ;; esac
  while [ -n "$p" ] && [ ! -d "$p" ]; do
    rest="/${p##*/}$rest"
    p="${p%/*}"
  done
  case "$rest/" in */./* | */../*) return 1 ;; esac
  p="$(cd "${p:-/}" && pwd -P)" || return 1
  if [ "$p" = / ]; then p=""; fi
  printf '%s\n' "${p}${rest:-}"
}

# under A B: A is B or below it (slash boundary).
under() {
  case "$1/" in "$2/"*) return 0 ;; esac
  return 1
}

# ps_records: normalise `ps -o pid=,lstart=,command=` lines on stdin to "pid SEP lstart SEP command".
ps_records() {
  local pid a b c d e cmd
  while read -r pid a b c d e cmd; do
    if [ -n "$pid" ]; then printf '%s%s%s %s %s %s %s%s%s\n' "$pid" "$SEP" "$a" "$b" "$c" "$d" "$e" "$SEP" "$cmd"; fi
  done
}

# snapshot_procs: the single process snapshot every ownership decision is made from, into $SNAP.
snapshot_procs() { ps -axww -o pid=,lstart=,command= | ps_records >"$SNAP"; }

# valid PID: the process still has the pid, start time and command of its snapshot line.
valid() {
  local want now
  want="$(awk -F "$SEP" -v p="$1" '$1 == p { print; exit }' "$SNAP")"
  now="$(ps -ww -o pid=,lstart=,command= -p "$1" 2>/dev/null | ps_records)"
  [ -n "$want" ] && [ "$now" = "$want" ]
}

# proc_cwd PID: the process's current directory (for report and refusal checks only).
proc_cwd() {
  if [ -L "/proc/$1/cwd" ]; then
    readlink "/proc/$1/cwd" 2>/dev/null || true
  else
    lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true
  fi
}

# stop_set PID...: SIGTERM each still-valid PID, wait up to 10 s for all of them to exit, then
# SIGKILL only survivors that still validate.
stop_set() {
  local p sent="" left
  for p in "$@"; do
    if valid "$p"; then
      if kill -TERM "$p" 2>/dev/null; then sent="$sent $p"; fi
    else
      echo "skip $p: pid, start time or command differs from the snapshot"
    fi
  done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    left=""
    for p in $sent; do
      if valid "$p"; then left="$left $p"; fi
    done
    [ -n "$left" ] || return 0
    sleep 1
  done
  for p in $sent; do
    if valid "$p"; then
      echo "SIGKILL $p"
      kill -KILL "$p" 2>/dev/null || true
    fi
  done
  sleep 1
}

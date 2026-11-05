#!/usr/bin/env bash
# close-run.sh — the mechanical steps of "Closing the run" (auto-mode loop procedures, steps 2, 6,
# 7 and 8): stop what the run started, remove its worktrees, clean its scratch, delete its merged
# PR branches, finalise the state file.
#
# Usage: bash .claude/scripts/close-run.sh [--apply] [--state <file>] [--trunk <branch>] [--prod <branch>]
#          [--prs 12,15] [--worktree <path>]... [--scratch-prefix P] [--scratch-pattern '<P>glob']...
#          [--skip processes|worktrees|scratch|branches]... [--closing-pr N --finalize-state] [--remote origin]
#
# Without --apply it only PLANS: it changes nothing (the worktree and scratch scripts run with
# --dry-run) and prints what each step would do. With --apply it does the steps below, and nothing
# else. It never merges or closes a PR, never pushes anything but the deletion of a merged PR's
# branch, and leaves to the caller (listed under `manual`) the steps that need judgment or another
# tool: tech-debt memories, the tracker, deliverables for the closing PR, CronDelete.
#
#   processes  The state file's "## Processes started" rows with an empty `stopped`. A row is
#              signalled (TERM, then KILL after 5 s) only while its pid still has the row's
#              `ps -o lstart=` and a command containing the row's command; a reused pid is reported
#              and left alone. `stopped` is filled with the time.
#   worktrees  Each --worktree, plus every .claude/worktrees/<name> the state file names, that is a
#              registered worktree: remove-worktree.sh (which refuses a live Codex job and preserves
#              evidence), then sweep-codex-orphans.sh when the codex pack installed it. A refusal is reported as blocked, never forced.
#   scratch    clean-scratch.sh --dry-run '<prefix>*' always, to list what remains for the owner;
#              with --apply it really cleans only the --scratch-pattern entries the run created.
#   branches   The PR numbers of --prs, else those in the state file's wave ledger and harness
#              self-improvement tables: for each PR whose state is MERGED, its head branch is
#              deleted on the remote if it is still there. Never <trunk>, <prod>, HEAD, main or
#              master, and never a branch of a PR that is not MERGED.
#   finalize   With --apply --finalize-state --closing-pr N, and only if PR N is MERGED: sets
#              `Cadence: none`, `Schedule: none` and status `done` in the state file. The CronDelete
#              of the old Schedule id is a tool call, so it is returned under `manual`.
#
# JSON: {mode, state, processes[], worktrees[], sweep, scratch, branches[], finalize, manual[],
# blocked}. Each entry carries an `action` (plan: would-stop, would-remove, would-delete; applied:
# stopped, removed, deleted, cleaned; else skipped, gone, reused-pid, not-a-worktree, blocked,
# failed) and a `detail`. Exit: 0 nothing blocked or failed, 1 something blocked or failed (do not
# set the run to done), 2 bad input.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
die() { echo "close-run: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

APPLY=0 STATE="" TRUNK="" PROD="" PRS="" PREFIX="${HARNESS_SCRATCH_PREFIX:-}" REMOTE=origin CLOSING="" FINALIZE=0
WTS="" PATTERNS="" SKIP=" "
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --finalize-state) FINALIZE=1 ;;
    --state) [ $# -ge 2 ] || die "--state needs a file"; STATE="$2"; shift ;;
    --trunk) [ $# -ge 2 ] || die "--trunk needs a branch"; TRUNK="$2"; shift ;;
    --prod) [ $# -ge 2 ] || die "--prod needs a branch"; PROD="$2"; shift ;;
    --prs) [ $# -ge 2 ] || die "--prs needs a list"; PRS="$2"; shift ;;
    --worktree) [ $# -ge 2 ] || die "--worktree needs a path"; WTS="$WTS$2
"; shift ;;
    --scratch-prefix) [ $# -ge 2 ] || die "--scratch-prefix needs a value"; PREFIX="$2"; shift ;;
    --scratch-pattern) [ $# -ge 2 ] || die "--scratch-pattern needs a glob"; PATTERNS="$PATTERNS$2
"; shift ;;
    --skip) [ $# -ge 2 ] || die "--skip needs a section"; SKIP="$SKIP$2 "; shift ;;
    --closing-pr) [ $# -ge 2 ] || die "--closing-pr needs a number"; CLOSING="$2"; shift ;;
    --remote) [ $# -ge 2 ] || die "--remote needs a name"; REMOTE="$2"; shift ;;
    *) die "unknown option: $1 (see the header of close-run.sh)" ;;
  esac
  shift
done
case "$CLOSING" in *[!0-9]*) die "--closing-pr must be a whole number" ;; esac
[ "$FINALIZE" = 0 ] || [ -n "$CLOSING" ] || die "--finalize-state needs --closing-pr"

COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || die "not inside a git checkout"
MAIN="$(cd "$COMMON/.." && pwd -P)"
cd "$MAIN" || exit 2
[ -n "$STATE" ] || STATE="$MAIN/.claude/auto-mode/state.md"
[ -r "$STATE" ] || die "state file missing or unreadable: $STATE"
[ -n "$PREFIX" ] || PREFIX="$(basename "$MAIN")-"
skipped() { case "$SKIP" in *" $1 "*) return 0 ;; esac; return 1; }

TMP="$(mktemp -d)" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT
for f in processes worktrees branches; do : >"$TMP/$f.ndjson"; done
BLOCKED=0
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# rec <file> <action> <subject> <detail>: one result entry; blocked and failed ones are counted
rec() {
  jq -nc --arg a "$2" --arg s "$3" --arg d "$4" '{action: $a, subject: $s, detail: $d}' >>"$TMP/$1.ndjson"
  case "$2" in blocked | failed) BLOCKED=$((BLOCKED + 1)) ;; esac
}
squeeze() { tr -s ' \t' '  ' | sed 's/^ //; s/ $//'; }

# --- processes ---
SEP="$(printf '\037')"
proc_rows() {
  awk -F '|' -v sep="$SEP" '
    /^## / { in_s = ($0 ~ /^## Processes started/); next }
    in_s && /^\|/ {
      for (i = 2; i <= 6; i++) { c[i] = $i; gsub(/^[ \t]+|[ \t]+$/, "", c[i]) }
      if (c[2] ~ /^[0-9]+$/ && c[6] == "") print c[2] sep c[3] sep c[4] sep c[5]
    }' "$STATE"
}
mark_stopped() { # mark_stopped <pid> <text>: fill the row's `stopped`
  awk -F '|' -v OFS='|' -v pid="$1" -v when="$2" '
    /^## / { in_s = ($0 ~ /^## Processes started/) }
    in_s && /^\|/ && !done { c = $2; gsub(/[ \t]/, "", c); s = $6; gsub(/[ \t]/, "", s); if (c == pid && s == "") { $6 = " " when " "; done = 1 } }
    { print }' "$STATE" >"$TMP/state.new" && cat "$TMP/state.new" >"$STATE"
}
if ! skipped processes; then
  while IFS="$SEP" read -r pid lstart cmd _why; do
    [ -n "$pid" ] || continue
    cur_l="$(ps -o lstart= -p "$pid" 2>/dev/null | squeeze)"
    cur_c="$(ps -o command= -p "$pid" 2>/dev/null)"
    if [ -z "$cur_l" ]; then
      rec processes gone "$pid" "no such process"
      [ "$APPLY" = 0 ] || mark_stopped "$pid" "$NOW (already gone)"
    elif [ "$cur_l" != "$(printf '%s' "$lstart" | squeeze)" ] || { [ -n "$cmd" ] && case "$cur_c" in *"$cmd"*) false ;; *) true ;; esac; }; then
      rec processes reused-pid "$pid" "pid $pid now has start '$cur_l' and another command; not signalled"
    elif [ "$APPLY" = 0 ]; then
      rec processes would-stop "$pid" "$cmd"
    else
      kill -TERM "$pid" 2>/dev/null
      n=0
      while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 0.5; n=$((n + 1)); done
      if kill -0 "$pid" 2>/dev/null && [ "$(ps -o lstart= -p "$pid" 2>/dev/null | squeeze)" = "$cur_l" ]; then
        kill -KILL "$pid" 2>/dev/null
        sleep 0.5
      fi
      if kill -0 "$pid" 2>/dev/null && [ "$(ps -o lstart= -p "$pid" 2>/dev/null | squeeze)" = "$cur_l" ]; then
        rec processes failed "$pid" "still running after TERM and KILL"
      else
        rec processes stopped "$pid" "$cmd"
        mark_stopped "$pid" "$NOW"
      fi
    fi
  done < <(proc_rows)
fi

# --- worktrees and the orphan sweep ---
SWEEP='null'
if ! skipped worktrees; then
  grep -oE '\.claude/worktrees/[A-Za-z0-9._-]+' "$STATE" | sort -u | while IFS= read -r w; do echo "$MAIN/$w"; done >"$TMP/statewts"
  { printf '%s' "$WTS"; cat "$TMP/statewts"; } | sed '/^$/d' | sort -u >"$TMP/wts"
  git worktree list --porcelain | sed -n 's/^worktree //p' >"$TMP/registered"
  while IFS= read -r w; do
    if ! grep -qxF -- "$w" "$TMP/registered"; then rec worktrees not-a-worktree "$w" "not a registered worktree (already removed?)"; continue; fi
    if [ "$APPLY" = 0 ]; then
      out="$(bash "$HERE/remove-worktree.sh" --dry-run "$w" 2>&1)"; rc=$?
      if [ "$rc" = 0 ]; then rec worktrees would-remove "$w" "$(printf '%s' "$out" | tail -n 3)"; else rec worktrees blocked "$w" "$(printf '%s' "$out" | tail -n 6)"; fi
    else
      out="$(bash "$HERE/remove-worktree.sh" "$w" 2>&1)"; rc=$?
      if [ "$rc" = 0 ]; then rec worktrees removed "$w" "$(printf '%s' "$out" | tail -n 3)"; else rec worktrees blocked "$w" "$(printf '%s' "$out" | tail -n 6)"; fi
    fi
  done <"$TMP/wts"
  if [ -f "$HERE/sweep-codex-orphans.sh" ]; then
    if [ "$APPLY" = 0 ]; then out="$(bash "$HERE/sweep-codex-orphans.sh" --dry-run 2>&1)"; rc=$?; else out="$(bash "$HERE/sweep-codex-orphans.sh" 2>&1)"; rc=$?; fi
    SWEEP="$(jq -nc --argjson rc "$rc" --arg o "$(printf '%s' "$out" | tail -n 40)" --argjson dry "$((1 - APPLY))" '{dry_run: ($dry == 1), exit: $rc, output: $o}')"
    [ "$rc" = 0 ] || BLOCKED=$((BLOCKED + 1))
  else
    # The orphan sweep ships with the codex pack; without it there are no companion brokers to stop.
    SWEEP='{"skipped": true, "reason": "codex pack not installed"}'
  fi
fi

# --- scratch ---
SCRATCH='null'
if ! skipped scratch; then
  out="$(HARNESS_SCRATCH_PREFIX="$PREFIX" bash "$HERE/clean-scratch.sh" --dry-run "${PREFIX}*" 2>&1)"; rc=$?
  CLEANED='[]'
  if [ "$APPLY" = 1 ]; then
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      o2="$(HARNESS_SCRATCH_PREFIX="$PREFIX" bash "$HERE/clean-scratch.sh" "$pat" 2>&1)"; r2=$?
      CLEANED="$(printf '%s' "$CLEANED" | jq -c --arg p "$pat" --argjson r "$r2" --arg o "$(printf '%s' "$o2" | tail -n 20)" '. + [{pattern: $p, exit: $r, output: $o}]')"
      [ "$r2" = 0 ] || BLOCKED=$((BLOCKED + 1))
    done <<EOP
$PATTERNS
EOP
  fi
  SCRATCH="$(jq -nc --arg prefix "$PREFIX" --argjson rc "$rc" --arg o "$(printf '%s' "$out" | tail -n 40)" --argjson cleaned "$CLEANED" \
    '{prefix: $prefix, remaining_listing: {exit: $rc, output: $o}, cleaned: $cleaned, note: "entries the run did not create are left for the owner"}')"
fi

# --- merged PR branches ---
if ! skipped branches; then
  if [ -z "$PRS" ]; then
    PRS="$(awk '/^## /{ in_s = ($0 ~ /^## (Wave ledger|Harness self-improvement)/); next } in_s && /^\|/' "$STATE" | grep -oE '#[0-9]+' | tr -d '#' | sort -un | tr '\n' ',')"
  fi
  if ! command -v gh >/dev/null 2>&1; then
    rec branches blocked "-" "gh is not installed, so merged PRs cannot be identified"
  else
    printf '%s' "$PRS" | tr ',' '\n' | sed '/^$/d' | while IFS= read -r n; do
      info="$(gh pr view "$n" --json state,headRefName -q '.state + " " + .headRefName' 2>/dev/null)" || info=""
      st="${info%% *}" br="${info#* }"
      if [ -z "$info" ]; then rec branches failed "#$n" "gh pr view failed"; continue; fi
      if [ "$st" != MERGED ]; then rec branches skipped "#$n" "state $st, branch $br left alone"; continue; fi
      case "$br" in
        HEAD | main | master | "$TRUNK" | "$PROD") rec branches skipped "#$n" "$br is protected"; continue ;;
      esac
      if ! git ls-remote --exit-code --heads "$REMOTE" "$br" >/dev/null 2>&1; then rec branches skipped "#$n" "$br is already gone on $REMOTE"; continue; fi
      if [ "$APPLY" = 0 ]; then rec branches would-delete "#$n" "$br"
      elif git push -q "$REMOTE" --delete "$br" >/dev/null 2>&1; then rec branches deleted "#$n" "$br"
      else rec branches failed "#$n" "git push $REMOTE --delete $br failed"; fi
    done
    # the loop ran in a subshell: recount the problems from the file
    BLOCKED=$((BLOCKED + $(grep -cE '"action":"(blocked|failed)"' "$TMP/branches.ndjson" || true)))
  fi
fi

# --- finalize the state file ---
FINAL='{"requested":false}'
OLD_SCHEDULE="$(sed -n 's/^- Schedule:[[:space:]]*//p' "$STATE" | head -n 1)"
if [ "$FINALIZE" = 1 ]; then
  if [ "$APPLY" = 0 ]; then
    FINAL="$(jq -nc --arg n "$CLOSING" '{requested: true, applied: false, detail: ("would set Cadence none, Schedule none and status done once PR #" + $n + " is MERGED")}')"
  elif ! command -v gh >/dev/null 2>&1 || [ "$(gh pr view "$CLOSING" --json state -q .state 2>/dev/null)" != MERGED ]; then
    FINAL="$(jq -nc --arg n "$CLOSING" '{requested: true, applied: false, detail: ("the closing PR #" + $n + " is not MERGED (or gh is unavailable); the state file is unchanged")}')"
    BLOCKED=$((BLOCKED + 1))
  elif [ "$BLOCKED" -gt 0 ]; then
    FINAL='{"requested":true,"applied":false,"detail":"an earlier step is blocked or failed; the state file is unchanged"}'
  else
    awk '
      /^## / { sec = $0; if (sec ~ /^## Status/) st = 1; else st = 0 }
      st && NF && $0 !~ /^## / && !done { print "done"; done = 1; next }
      sec ~ /^## Checkpoints/ && /^- Cadence:/ { print "- Cadence: none"; next }
      sec ~ /^## Checkpoints/ && /^- Schedule:/ { print "- Schedule: none"; next }
      { print }' "$STATE" >"$TMP/state.new" && cat "$TMP/state.new" >"$STATE"
    FINAL='{"requested":true,"applied":true,"detail":"Cadence none, Schedule none, status done"}'
  fi
fi

MANUAL='["tech-debt memories: mark those whose fix merged this run resolved (cite path:line on the trunk), reversed decisions superseded","tracker: the goal'"'"'s parent ticket or epic to Done, and close any run ledger","deliverables meant for the trunk (audit reports) go into the closing PR after a secret scan, or the decision log says why not"]'
case "$OLD_SCHEDULE" in
  "" | none) ;;
  *) MANUAL="$(printf '%s' "$MANUAL" | jq -c --arg id "$OLD_SCHEDULE" '. + ["CronList, then CronDelete the checkpoint schedule id " + $id + " (a tool call; load both with ToolSearch), and stop scheduling heartbeats"]')" ;;
esac

jq -n --arg mode "$([ "$APPLY" = 1 ] && echo apply || echo plan)" --arg state "$STATE" --slurpfile p "$TMP/processes.ndjson" \
  --slurpfile w "$TMP/worktrees.ndjson" --slurpfile b "$TMP/branches.ndjson" --argjson sweep "$SWEEP" --argjson scratch "$SCRATCH" \
  --argjson final "$FINAL" --argjson manual "$MANUAL" --argjson blocked "$BLOCKED" \
  '{mode: $mode, state: $state, processes: $p, worktrees: $w, sweep: $sweep, scratch: $scratch, branches: $b, finalize: $final, manual: $manual, blocked: $blocked}'
[ "$BLOCKED" = 0 ]

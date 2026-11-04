#!/usr/bin/env bash
# blind-candidates.sh — prepare candidate reports or plans for a blind judge: keep the raw copies
# in a private folder, flip the order, and write copies with every authorship tell stripped.
#
# Usage: bash .claude/scripts/blind-candidates.sh --kind arch|plan --slug <slug> [--dir <plans dir>]
#                  [--seed N] [--keep <term>]... [--force] NAME=FILE NAME=FILE [NAME=FILE]
#   NAME=FILE   an engine label (lowercase letters, digits, - and _; e.g. claude, codex) and the file
#               holding that engine's raw output; two or three candidates
#   --dir       the plans dir; default <main checkout>/.claude/plans
#   --seed      seeds the shuffle (a repeatable order, for tests); unseeded, the order is random
#   --keep T    do not strip the term T (the project's own subject matter names that tool or model)
#   --force     overwrite anonymised copies that already exist (default: refuse, so a judge's inputs
#               are never silently re-shuffled)
#
# Writes, under <dir>:
#   <slug>.private/<kind>-<NAME>.md   the raw outputs, verbatim (never a bare claude.md: macOS's
#                                     case-insensitive filesystem would load it as a CLAUDE.md)
#   <slug>.private/mapping.md         one line appended per run: `<kind>: A=codex B=claude`
#   kind arch: <slug>.arch-a.md, .arch-b.md, [.arch-c.md]
#   kind plan: <slug>.candidate-a.md, .candidate-b.md, [.candidate-c.md]   (labelled A, B, C in
#                                     the shuffled order)
# Stripped from the anonymised copies: engine and model names (codex, claude, gpt, gemini, opus,
# sonnet, haiku, anthropic, openai, glm, kimi, qwen, deepseek, argon, opencode, omp), each with a
# trailing version suffix such as -5.1 or -opus-4; "generated/written/produced/authored/reviewed
# by" lines and session, job, task, thread or run id lines; UUIDs and task-<id> style ids. The
# substance and the length are otherwise verbatim.
#
# JSON on stdout: {kind, slug, candidates:[{label, path}], private_dir, mapping_file, removed_lines,
# residual_tells}. The order is NOT printed: read it from the mapping file only after the verdict,
# and never pass the private folder or the mapping to the judge. residual_tells counts lines of the
# anonymised copies that still match a tell (0 unless a --keep term leaves some); check it.
# Exit: 0 done, 2 bad input.
set -u

die() { echo "blind-candidates: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is not installed"

KIND="" SLUG="" DIR="" SEED="" FORCE=0 KEEP=""
NAMES="" FILES="" # parallel lists, one entry per line
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) [ $# -ge 2 ] || die "--kind needs arch or plan"; KIND="$2"; shift ;;
    --slug) [ $# -ge 2 ] || die "--slug needs a value"; SLUG="$2"; shift ;;
    --dir) [ $# -ge 2 ] || die "--dir needs a directory"; DIR="$2"; shift ;;
    --seed) [ $# -ge 2 ] || die "--seed needs a number"; SEED="$2"; shift ;;
    --keep) [ $# -ge 2 ] || die "--keep needs a term"; KEEP="$KEEP
$2"; shift ;;
    --force) FORCE=1 ;;
    -*) die "unknown option: $1" ;;
    *=*)
      n="${1%%=*}"
      case "$n" in '' | *[!a-z0-9_-]*) die "bad candidate name (lowercase letters, digits, - and _): $n" ;; esac
      [ -f "${1#*=}" ] || die "no such file for $n: ${1#*=}"
      NAMES="$NAMES$n
"
      FILES="$FILES${1#*=}
" ;;
    *) die "usage: blind-candidates.sh --kind arch|plan --slug S [--dir D] NAME=FILE NAME=FILE [NAME=FILE]" ;;
  esac
  shift
done
case "$KIND" in arch | plan) ;; *) die "--kind must be arch or plan" ;; esac
case "$SLUG" in '' | *[!A-Za-z0-9._-]*) die "--slug must match [A-Za-z0-9._-]+" ;; esac
case "$SEED" in *[!0-9]*) die "--seed must be a whole number" ;; esac
N="$(printf '%s' "$NAMES" | grep -c .)"
[ "$N" -ge 2 ] && [ "$N" -le 3 ] || die "give two or three NAME=FILE candidates"
[ "$(printf '%s' "$NAMES" | sort -u | wc -l | tr -d ' ')" = "$N" ] || die "candidate names must be distinct"

if [ -z "$DIR" ]; then
  COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || die "not in a git checkout; pass --dir"
  DIR="$(cd "$COMMON/.." && pwd -P)/.claude/plans"
fi
mkdir -p "$DIR" || die "cannot create $DIR"
PRIV="$DIR/$SLUG.private"
mkdir -p "$PRIV" && chmod 700 "$PRIV" || die "cannot create $PRIV"

# Shuffle the candidate positions 1..N (Fisher-Yates).
[ -z "$SEED" ] || RANDOM="$SEED"
arr=()
for ((i = 0; i < N; i++)); do arr[i]=$((i + 1)); done
for ((j = N - 1; j > 0; j--)); do
  k=$((RANDOM % (j + 1)))
  t="${arr[j]}"; arr[j]="${arr[k]}"; arr[k]="$t"
done
ORDER="${arr[*]}"

case "$KIND" in arch) STEM="$SLUG.arch-" ;; plan) STEM="$SLUG.candidate-" ;; esac
pick() { printf '%s\n' "$2" | sed -n "${1}p"; } # pick <line number> <list>

# ci <word>: the word as a case-insensitive bracket pattern (BSD sed has no I flag).
ci() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z]) out="${out}[$(printf %s "$c" | tr a-z A-Z)$(printf %s "$c" | tr A-Z a-z)]" ;;
      *) out="$out$c" ;;
    esac
  done
  printf '%s' "$out"
}
TERMS="" ALL=""
for t in codex claude gpt gemini opus sonnet haiku anthropic openai glm kimi qwen deepseek argon opencode omp; do
  ALL="$ALL${ALL:+|}$(ci "$t")"
  if printf '%s\n' "$KEEP" | tr 'A-Z' 'a-z' | grep -qx "$t"; then continue; fi
  TERMS="$TERMS${TERMS:+|}$(ci "$t")"
done
LINE_RE="[[:space:]]*[-_*>#]*[[:space:]]*((($(ci generated)|$(ci written)|$(ci produced)|$(ci authored)|$(ci reviewed))[[:space:]]+$(ci by)[[:space:]])|(($(ci session)|$(ci job)|$(ci task)|$(ci thread)|$(ci run))[ _-]?$(ci id)([^A-Za-z]|\$)))"
W='[^A-Za-z0-9_]'

anonymise() { # stdin -> stdout
  grep -Ev -e "^($LINE_RE)" | sed -E \
    -e "s/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<id>/g" \
    -e "s/($(ci task)|$(ci job)|$(ci session)|$(ci run)|$(ci thread))[-_][A-Za-z0-9]{6,}/<id>/g" |
    if [ -n "$TERMS" ]; then
      sed -E -e "s/(^|$W)($TERMS)(-[A-Za-z0-9.]+)*/\\1<redacted>/g" -e "s/(^|$W)($TERMS)(-[A-Za-z0-9.]+)*/\\1<redacted>/g"
    else
      cat
    fi
}

# Refuse to re-shuffle inputs a judge may already have.
idx=1
for pos in $ORDER; do
  out="$DIR/$STEM$(printf '%s' "$idx" | tr 123 abc).md"
  [ "$FORCE" = 1 ] || [ ! -e "$out" ] || die "$out exists (use --force to overwrite)"
  idx=$((idx + 1))
done

MAPLINE="$KIND:" REMOVED=0 RESIDUAL=0 CANDS="[]"
idx=1
for pos in $ORDER; do
  name="$(pick "$pos" "$NAMES")"
  src="$(pick "$pos" "$FILES")"
  label="$(printf '%s' "$idx" | tr 123 ABC)"
  out="$DIR/$STEM$(printf '%s' "$label" | tr ABC abc).md"
  cp "$src" "$PRIV/$KIND-$name.md" || die "cannot copy $src"
  anonymise <"$src" >"$out" || true
  REMOVED=$((REMOVED + $(wc -l <"$src") - $(wc -l <"$out")))
  RESIDUAL=$((RESIDUAL + $(grep -Ec -e "(^|$W)($ALL)([^A-Za-z0-9_]|\$)" "$out" || true)))
  MAPLINE="$MAPLINE $label=$name"
  CANDS="$(printf '%s' "$CANDS" | jq -c --arg l "$label" --arg p "$out" '. + [{label: $l, path: $p}]')"
  idx=$((idx + 1))
done
printf '%s\n' "$MAPLINE" >>"$PRIV/mapping.md"

jq -n --arg kind "$KIND" --arg slug "$SLUG" --argjson c "$CANDS" --arg priv "$PRIV" --arg map "$PRIV/mapping.md" \
  --argjson removed "$REMOVED" --argjson residual "$RESIDUAL" \
  '{kind: $kind, slug: $slug, candidates: $c, private_dir: $priv, mapping_file: $map, removed_lines: $removed, residual_tells: $residual}'

---
allowed-tools: Read, Write, Bash, Glob, Grep
description: Ask a different-model engine (omp:codex) for a second opinion; --advisor makes it an adversarial, read-only critique
argument-hint: [--advisor] <question / plan / decision / task for the other engine>
model: inherit
---

# /second-opinion — different-model second opinion (omp:codex, read-only)

You have a standing second engine: a DIFFERENT model family (Codex / GPT-5.x, run by omp) reachable any time you
are unsure, weighing a tradeoff, or about to commit to something hard to reverse. Its value is **uncorrelated
blind spots** — it catches what a second Claude pass cannot, because same-model self-review samples the same
distribution that produced the error.

Question / material: $ARGUMENTS

If `$ARGUMENTS` is empty, ask the user what they want the other engine to look at before dispatching anything.
A leading `--advisor` selects advisor mode (below) and is removed from the material; without it the user's text
goes to the engine as the task, verbatim.

## Steps

1. **Brief tightly.** Assemble the decision / plan / diff and the constraints that matter. Do not dump the whole
   repo — give the engine exactly what it needs to judge. Write the brief to a scratch file
   (`BRIEF="$(mktemp "${TMPDIR:-/tmp}/second-opinion.XXXXXX")"`).
   - **Default mode:** the brief is the user's prompt plus the context it needs.
   - **`--advisor` mode:** the brief is the block below with `{brief}` and `{constraints}` filled in:
     ```
     READ-ONLY adversarial second opinion — advise, do NOT implement or edit anything. You are a
     senior staff engineer, a DIFFERENT model with uncorrelated blind spots, NOT the author.
     Disagree on substance, not style; no praise, no filler. If sound, say so with your confidence;
     if risky, RANK the risks worst-first and STEELMAN the alternative you would choose. State what
     you CANNOT assess from the material. End with VERDICT: endorse | endorse-with-changes | reject.
     Material: {brief}. Constraints: {constraints}.
     Do NOT write any file: return the full critique as your final message text.
     ```
2. **Call it** in the foreground and wait for the full result (never return only a job id or run it in the
   background):
   ```bash
   bash .claude/scripts/routing.sh engines architect        # the omp:codex row names the profile and model
   bash .claude/scripts/omp-engine.sh ask --engine omp:codex --role architect \
     --brief "$BRIEF" --out "$OUT" --repo "$PWD"            # add --no-tools for a pure text critique
   ```
   `$OUT` is a scratch file; the answer is its content, and `$OUT.json` carries the result and recovery
   metadata. The brief asks for text only; the artifact comes back as text, never as a file in the repo.
3. **Synthesize — never just forward.** Read its answer, judge it, report back: the question asked + the
   engine's verbatim verdict + YOUR synthesis (agree / disagree / what to actually do). On disagreement, do ONE
   reconcile call ("I found X, you suggest Y — which constraint breaks the tie?") before deciding. Escalate
   unresolved CRITICAL risks to the user.
4. **Gate the call rate.** Use it for high-value, hard-to-reverse, or low-confidence decisions — not
   naming/style. Over-calling adds noise, not signal.

If the engine is unavailable (the `omp:codex` row is missing or capped, a capacity or 429 error that survives
the one retry after about 60 s, or `omp-engine.sh` exits 3, 4 or 5), say so and proceed on your own judgment —
fail-warn, never fail-stop. Never present a single-engine result as a second opinion.

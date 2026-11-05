# Code-review-bot command hooks

Moved out of core `loop-procedures.md` (step 6, polling). CodeRabbit mention syntax; adapt it to your bot.

## Drive the bot, don't wait on it

If you run an AI code-review bot such as CodeRabbit, it typically auto-reviews every PR
into your release/staging branches and re-reviews on every push (check your bot's config
for `base_branches` + an auto-incremental-review setting), so you rarely need to force a
review. Drive it from the loop with `gh pr comment <N> --body "@coderabbitai <cmd>"` (or
your bot's equivalent mention syntax) at these points — never idle a poll cycle waiting
on it:

- **After you push fixes for ALL of the bot's actionable comments in a cycle** →
  `@coderabbitai resolve` (marks its threads resolved so the next poll sees a clean
  slate and the ≥1-clean-cycle merge bar is reached sooner).
- **Fallback — no bot status ~2 poll cycles after PR open, or on a PR it skipped** →
  `@coderabbitai review` (kick a review that didn't auto-trigger).
- **During a churn-heavy fixup burst** → `@coderabbitai pause` at the start,
  `@coderabbitai resume` once stable (stops re-review spam while you force-push several
  quick fixups). Always `resume` before evaluating the merge bar.
- Skip `full review`, `configure`, `generate docstrings` — manual/interactive only.

If your bot's config holds a PR in "changes requested" until its comments resolve, honor
it — the merge bar already requires zero new actionable comments, so fix or resolve,
never merge over an unresolved CRITICAL. If a pre-merge check blocks a wave on something
like docstring coverage, add the missing artifact (preferred) or, if it's genuinely noise
for that wave, note it in the decision log and relax the check in your bot's config
rather than wedging the loop.


# Harness self-improvement loop

Moved out of core `loop-procedures.md` (Parallel work). Needs two things added to the auto-mode state file: a `## Harness friction log` section (`- <date> <wave> <what in .claude/ slowed or misled the run> — <fixed in PR #NN | open>`) and a `## Harness self-improvement` table (`| Batch | Branch | Worktree | PR | State |`). `close-run.sh` reads that table when present.

## The loop

The run fixes its own harness as it goes. Whenever something in `.claude/` slows or misleads
a wave, add a line to the state file's **Harness friction log**. With each wave PR, run one batch. Plan
the batch as independent fix groups by file (no two groups edit the same file): one
implementer agent per group in its own worktree, one reviewer per group, and the group
branches merged into the batch branch. Steps 1–4 describe the batch branch; each group
worktree is cut and removed the same way.

Group briefs are sections of the batch plan file. A change during the run is written there, at
the top of the affected section, as `> REVISED <date -u +%Y-%m-%dT%H:%M:%SZ>: <what changed and
what to do>` or `> REVOKED <ISO>: <decision> — <replacement>`, before any message; every group
agent and the integrator record `shasum -a 256 <plan file>` when they start and re-hash it
before each commit and merge, applying every new REVISED or REVOKED line first (and stopping to
report when one contradicts work already committed). Group agents never read this file, so each
group brief carries that instruction itself, or names `implementer.md` → Step 3, item 3. A batch
acceptance check that names an open branch carries "once that branch is merged, run it against
`origin/{{STAGING_BRANCH}}`" (a check bound to a branch goes stale once it squash-merges).

1. `git worktree add .claude/worktrees/harness-<n> -b chore/harness-selfimprove-<n>
   origin/{{STAGING_BRANCH}}` — an isolated worktree, so the wave checkout is untouched.
2. Fix the logged frictions and the open gaps, editing only harness files (`.claude/`) that
   the open wave branch does not touch
   (`git diff --name-only origin/{{STAGING_BRANCH}}...<wave branch>`). A friction in a file the
   wave touches waits for the next batch.
3. External bugs (memory server, plugins, Codex runtime) are not fixed here: document the
   workaround in the skill or agent prompt that hits them.
4. Commit, push, PR into `{{STAGING_BRANCH}}`, then poll, capture a memory and squash-merge
   exactly like a wave. Mark the fixed friction lines `fixed in PR #NN`, close the gaps, and
   record the batch in **Harness self-improvement**. Remove the worktree after the merge with
   `.claude/scripts/remove-worktree.sh`, then sweep (see "Removing a worktree" below).


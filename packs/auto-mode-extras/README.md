# Pack: auto-mode-extras (shipping labels, review-bot hooks, harness self-improvement)

Three procedures that used to sit inside `skills/auto-mode/references/loop-procedures.md` and are not needed to run
the loop. Core's `/auto-mode` works without them: wave close flips the ticket to `Done`, a promotion merges and stops,
and the polling loop treats a review bot like any other reviewer.

```bash
./install.sh <target> --pack auto-mode-extras
./install.sh <target> --remove-pack auto-mode-extras
```

| File | What it adds |
| --- | --- |
| `skills/auto-mode/references/shipping-labels.md` | The `shipped:staging` / `shipped:prod` labels: when step 9 and step 11 apply them, flip-never-accumulate, the read-first full-replace label write, and the promotion-goal enumeration |
| `skills/auto-mode/references/review-bot-hooks.md` | CodeRabbit mention commands (`resolve`, `review`, `pause`, `resume`) at the right points of the polling loop, and how to treat a held "changes requested" |
| `skills/auto-mode/references/self-improvement-loop.md` | Fixing `.claude/` in a side worktree while a run goes: the friction log, the batch branch, independent fix groups, brief revision rules |

## What core keeps

- The label-set safeguard: a tracker's label write usually replaces the whole set, so read first and send the full set.
- The merge bar: zero new actionable review comments, and never merging over an unresolved CRITICAL.
- Without the self-improvement loop, record a friction in the state file's Decision log and hand the list to the owner when
  the run closes; do not edit `.claude/` mid-run.

## State file

`templates/auto-mode-state.md` no longer carries the `Shipping label`, `Harness friction log` or `Harness self-improvement`
entries. With this pack, add the friction log and the batch table (shapes are in `self-improvement-loop.md`) to the run's
state file; `close-run.sh` reads the batch table when it is there.

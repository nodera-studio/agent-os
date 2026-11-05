# Shipping-state labels (`shipped:staging` / `shipped:prod`)

Moved out of core `loop-procedures.md`. Step 9 (wave close) and step 11 (promotion) of the per-wave loop call into this file when the pack is installed; without it they apply no shipping label.

## What it is

`Done` in your tracker means "merged onto `{{STAGING_BRANCH}}`" (step 9) — it does NOT
say whether the code reached prod. Two mutually-exclusive labels make the real location
explicit and stop the same feature being rebuilt on the other branch (the "feature in
both main and staging" failure):

| Label             | Meaning                                       |
| ----------------- | ----------------------------------------------- |
| `shipped:staging` | Code is on `{{STAGING_BRANCH}}`, NOT yet on `{{PROD_BRANCH}}` |
| `shipped:prod`    | Code is live on `{{PROD_BRANCH}}` (production)  |

Set these up once in your issue tracker (as plain labels — no special ID scheme needed
beyond whatever your tracker assigns).

Flip, never accumulate: a ticket holds AT MOST one. `shipped:prod` supersedes
`shipped:staging`. `Done` + `shipped:staging` = merged to staging, awaiting prod.

**When the loop applies them.** `shipped:staging` at **wave close (step 9)**, AFTER the
wave's PR merges onto `{{STAGING_BRANCH}}`, for that wave's ticket. `shipped:prod` only
after the `{{STAGING_BRANCH}} → {{PROD_BRANCH}}` promotion merges (step 11), flipped for
EVERY ticket in the promotion (the main ticket + every wave sub-issue + parent epics):

- on a wave staging-merge → ensure the wave ticket has `shipped:staging`, no
  `shipped:prod`.
- on a `{{STAGING_BRANCH}} → {{PROD_BRANCH}}` promotion → flip each promoted ticket
  `shipped:staging` → `shipped:prod`.

If the merge does NOT happen this run (still polling, or blocked), apply NO shipping
label — the label tracks branch reality, not intent.

**Check whether your tracker's label-set write REPLACES the whole label set** (many do —
it's NOT additive like `blocks`/`links` typically are). If so, never pass just
`["shipped:staging"]`: that would strip `Feature`, `Bug`, etc. First read the ticket's
current labels, then pass the full desired set: keep the existing labels, drop the
opposite shipping label, add the target one. E.g. a ticket currently `["Feature"]`
landing on staging → save `["Feature", "shipped:staging"]`; later promoted to the release
branch → save `["Feature", "shipped:prod"]`.

**Promotion goals (`{{STAGING_BRANCH}} → {{PROD_BRANCH}}`).** A goal phrased "promote
staging → main" / "land the staging batch on main" is a step-11 promotion:
`{{STAGING_BRANCH}}` already carries many `Done`, `shipped:staging` tickets. On a
successful merge onto `{{PROD_BRANCH}}`, enumerate every ticket in the promotion diff
(`git log origin/{{PROD_BRANCH}}..origin/{{STAGING_BRANCH}} --pretty=%s | grep -oE
'{{TICKET_PREFIX}}-[0-9]+'`, plus their parent epics) and flip each `shipped:staging` →
`shipped:prod`. This is the moment the branch-divergence the labels exist to surface gets
resolved. (See the `release-flow` skill → `references/promote-runbook.md`.)


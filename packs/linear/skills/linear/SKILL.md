---
name: linear
description: >-
  Linear gotchas for this harness. Use with the Linear connector (mcp__*Linear* tools, tickets are
  `{{TICKET_PREFIX}}-###`) whenever a ticket is read, updated or commented on, or a wave flips a ticket's state
  or labels. The connector and the mnemosyne-linear skill cover the tools; this keeps only the traps.
---

# Linear gotchas

- Linear is the single source of truth for issue tracking. Never make a parallel TODO file or markdown checklist for work
  that has, or should have, a ticket; an autonomous wave loop already creates and flips tickets, so align with it.
- A label write REPLACES the whole label set. Read the ticket's current labels first and send the full desired set
  (keep the existing ones, swap only the shipping label), or `Feature` and `Bug` vanish.
- `save_*` tools mutate Linear: mirror what the user asked, never bulk-edit or change status speculatively.
- Keep ticket bodies PII-free where they will be quoted into commits or audit logs.

# Pack: linear (Linear gotchas)

A 12-line skill with the traps the Linear connector and the `mnemosyne-linear` skill do not tell you: no parallel
TODO file, a label write replaces the whole set, `save_*` mutates, keep ticket bodies PII-free. The tool list that
the old skill carried is gone because the connector describes its own tools.

```bash
./install.sh <target> --pack linear
```

Ships `skills/linear/SKILL.md` only. Install it where tickets use `{{TICKET_PREFIX}}-###` and a wave loop flips them.

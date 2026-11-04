---
# Pointed to by CLAUDE.md's "Language mode" section, not loaded every session: this glob matches only this file.
paths:
  - ".claude/rules/language-mode.md"
---
# Language mode

`LANGUAGE_MODE` is declared once per project, in its `CLAUDE.md` (written by `/bootstrap-project`, which asks
once). Values: `en` (the default, also when the token is missing or blank) and `ro`. `ro` is an opt-in mode,
used today only by the nodex project; never offer it or switch to it on your own.

## `en` (default)

Agent-facing and user-facing output is English.

## `ro`

| Romanian, with full diacritics (`ă â î ș ț`) | English, always |
| --- | --- |
| Chat replies to the user, reports, review summaries, plan and progress summaries | Code, identifiers, comments, file paths, commands and quoted tool output |
| | Commit messages and PR titles |
| | Every brief sent to a subagent or to an `omp:<engine>`, and what they return |

- Use the comma-below letters `ș` and `ț`, never the cedilla forms `ş` and `ţ`; never drop a diacritic to
  "keep it simple".
- Engines never see Romanian. Brief them in English; Claude translates their findings into Romanian for the
  user and keeps `file:line` references and identifiers verbatim. Translating a finding does not change its
  severity, and the report still says how many engines took part.
- Diacritic regression gate: when you edit a Romanian file (a locale file, copy, a document), the count of
  diacritics must not drop. Run `bash .claude/scripts/copywrite-checks.sh diacritics --class 'ăâîșțĂÂÎȘȚ'
  --before-file <before> --after-file <after>` and revert the edit when `ok` is false.
- The Romanian copywriting pipeline (`agents/copywrite/`) keeps its own rules; this file only sets the language
  of the conversation.

# Pack: copywrite (user-facing copy to Apple voice)

`/copywrite` and the six-agent suite behind it. The orchestrator dispatches the voice editor (with sentence-level
surgery) and the microcopy specialist in parallel, then runs the localization editor and the consistency checker
as gates, merges the findings into a report (default) or edits in place (`--apply`), and runs three pre-write
gates: ICU `isStructurallySame()` for plural strings, a Babel re-parse for TSX files, and a diacritic and script
survival check (the Romanian gates). It is generic mechanism with no per-project vocabulary, and only useful
where the project has user-facing copy, so core does not carry it. `/bootstrap-project` asks the question.

```bash
./install.sh <target> --pack copywrite
./install.sh <target> --remove-pack copywrite
```

## What it ships

| File | Role |
| --- | --- |
| `commands/copywrite.md` | The slash command and its flags |
| `agents/copywrite/orchestrator.md` | Pipeline manager: scope, dispatch, merge, gates, write |
| `agents/copywrite/voice-editor.md` | Apple voice transfer and sentence-level surgery |
| `agents/copywrite/microcopy-specialist.md` | Buttons, toasts, errors, empty states, ICU plural quarantine, the pattern catalogue |
| `agents/copywrite/localization-editor.md` | Cross-locale register and cultural adaptation |
| `agents/copywrite/consistency-checker.md` | Glossary, cross-locale parity, diacritic and script gate |
| `agents/copywrite/voice-rubric.md` | The 9-rule distillation every specialist loads |
| `agents/copywrite/apple-style-guide.md` | The unabridged Apple Style Guide (verbatim third-party material, about 8,700 lines) |
| `agents/copywrite/*.template` | Skeletons to fill in: the canonical spelling glossary and the register memo |

## The Apple Style Guide is read by grep, not loaded

The voice editor used to load the whole guide on every dispatch, roughly 120k tokens. It now reads
`voice-rubric.md` in full and greps `apple-style-guide.md` for the single entry it needs (entries begin with the
bold term at the start of a line, under the A-Z headings), reading a few dozen lines around the match. The guide
still wins over the rubric when the two conflict.

## Before first use

Fill in `brand-terms.md.template` and `localization-register-memo.md.template` (rename them without `.template`)
with this project's glossary and register decisions.

## Core pieces it relies on

`scripts/copywrite-checks.sh` (the mechanical gates: dash, icu, babel, diacritics, parity, glossary) stays in
core, because `rules/language-mode.md` uses its diacritic gate for any Romanian file Claude edits. The pack's
agents call it through that path.

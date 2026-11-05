# Pack: playwright (browser automation and Playwright tests)

The `playwright-cli` skill as a thin wrapper plus three merged references. The old skill was a 396-line copy of
`playwright-cli --help` and ten reference files; this keeps what `--help` does not tell you.

```bash
./install.sh <target> --pack playwright
./install.sh <target> --remove-pack playwright
```

| File | Role |
| --- | --- |
| `skills/playwright-cli/SKILL.md` | About 50 lines: the snapshot-then-act loop and the rules (refs, `--raw`, screenshots, named sessions) |
| `skills/playwright-cli/references/testing.md` | Run and debug (`--debug=cli` plus `attach`), generate test code, and the plan, generate and heal workflow. Merges playwright-tests, test-generation and spec-driven-testing |
| `skills/playwright-cli/references/recipes.md` | `run-code`, request mocking, storage state, sessions, and a three-line tracing note. Merges running-code, request-mocking, storage-state and session-management |
| `skills/playwright-cli/references/video-recording.md` | The scripted `page.screencast` recording and overlay API, about 40 lines |

Cut: `element-attributes.md` (the `eval` examples are in the skill) and `tracing.md` (generic). The old skill's trigger text
named one project's dev URL; it now says "the project's dev URL (see CLAUDE.md)".

Needs `playwright-cli` (`npm install -g @playwright/cli@latest`) on the machine; the pack does not install it.

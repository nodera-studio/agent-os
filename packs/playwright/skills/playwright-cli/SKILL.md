---
name: playwright-cli
description: >
  Drive a real browser from the terminal with `playwright-cli`. Use when verifying UI behavior after a change,
  reproducing a frontend bug, taking screenshots, inspecting elements, console or network, exercising a flow end to end
  against the project's dev stack, or authoring and debugging Playwright tests. Triggers on: "verify the UI",
  "screenshot", "check the page", "click through the flow", "inspect element", "does it render", Playwright test debugging.
argument-hint: '[url or flow to verify, e.g. /invoices list renders after login]'
allowed-tools: Bash(playwright-cli:*) Bash(npx:*) Bash(npm:*)
---

# Browser automation with playwright-cli

This is a thin wrapper. `playwright-cli --help` and `playwright-cli <command> --help` list every command and flag;
do not memorise them. If the command is missing, try `npx --no-install playwright-cli --version`, else
`npm install -g @playwright/cli@latest`.

## The loop

```bash
playwright-cli open <dev-url>                 # the project's dev URL (see CLAUDE.md), in-memory profile
playwright-cli snapshot                       # YAML of the page with refs e1, e2, ...
playwright-cli fill e5 "user@example.com" --submit
playwright-cli click e12
playwright-cli snapshot                       # every command prints a fresh snapshot path; read the file
playwright-cli screenshot --filename=after.png
playwright-cli close
```

## Rules

- Target elements by the refs from the latest snapshot. Fall back to a CSS selector or a Playwright locator
  (`"getByRole('button', { name: 'Submit' })"`, `"getByTestId('submit-button')"`) when a ref is stale.
- Use `--raw` to get only the result value (pipe it into `jq`), `--json` for a structured reply.
- Look at the page, not just the DOM: for rendered output, take a screenshot and inspect it before reporting success.
- Read errors and traffic with `console` and `requests` (then `request <n>`); read attributes with
  `eval "el => el.getAttribute('data-testid')" e5`; get a locator for an assertion with `--raw generate-locator e5`.
- Isolate parallel work with a named session (`-s=NAME`); `list` shows sessions, `close-all` and `kill-all` clean up.
  `--persistent` or `--profile=DIR` keeps a profile on disk; `attach --cdp=...` joins an already running browser.
- `show --annotate` asks the user to point at something on the page. Dialogs: `dialog-accept` or `dialog-dismiss`.
- Never put secrets on a command line that will be logged. Never save auth state (`state-save`) into the repository.
- Close the browser when done; a leftover browser keeps the session's profile locked.

## References

- [Testing: run, debug, generate, plan and heal Playwright tests](references/testing.md)
- [Recipes: `run-code`, request mocking, storage state, sessions](references/recipes.md)
- [Video recording and annotated demos](references/video-recording.md)

# Testing: run, debug, generate, plan and heal

Merged from the old playwright-tests, test-generation and spec-driven-testing references. The three sections at the
end (plan, generate, heal) can be used independently; all of them lean on `--debug=cli` plus `attach`.

## Run and debug

```bash
PLAYWRIGHT_HTML_OPEN=never npx playwright test                       # never open the HTML report
PLAYWRIGHT_HTML_OPEN=never npx playwright test path/to/a.spec.ts:42 --debug=cli   # one test, paused at the start
playwright-cli attach tw-abcdef                                       # the session name is in the printed instructions
```

- Run the `--debug=cli` command **in the background** and read its output until "Debugging Instructions" appears. Stop it
  when you are done.
- The test is paused at the start. Step to just before the failing action, then explore with `snapshot`, `console`,
  `requests`, `show --annotate`. Every `playwright-cli` action prints the Playwright TypeScript it ran: paste that into the
  test. Usually a locator or an expectation changes; it can also be a real bug in the app, so use judgement.
- Never fix a test with a sleep, a skipped hook or `networkidle`.

## Generating test code

Collect the printed `await page....` lines into a test, then add assertions by hand (generated code has actions only):

```bash
playwright-cli --raw generate-locator e5          # a stable locator for the assertion
playwright-cli --raw eval "el => el.textContent" e5   # expected text   (el.value for inputs)
playwright-cli --raw snapshot e5                  # expected aria snapshot for toMatchAriaSnapshot
```

- Prefer role, label and test-id locators over CSS. Use `toBeVisible()`, `toHaveText()`, `toHaveValue()`, `toBeChecked()`,
  `toMatchAriaSnapshot()`. When the locator is text-based, assert `toBeVisible()` instead of the same text.
- An aria snapshot needs only what the assertion needs; use regular expressions for unstable values.

## Plan

Goal: a spec file, always written to disk, e.g. `specs/<feature>.plan.md`.

1. **Workspace:** `test -f playwright.config.ts || npx --no-install playwright --version`; else `npm init playwright@latest`.
2. **Seed test:** a minimal test that lands the page in the state every scenario starts from (navigation, login, flags),
   preferably through a fixture in `tests/fixtures.ts`. `--debug=cli` pauses inside it. Create one if missing.
   ```ts
   // tests/fixtures.ts
   import { test as baseTest } from '@playwright/test';
   export { expect } from '@playwright/test';
   export const test = baseTest.extend({
     page: async ({ page }, use) => { await page.goto('<dev-url>'); await use(page); },
   });
   // tests/seed.spec.ts: test('seed', async ({ page }) => { /* the fixture already navigates */ });
   ```
3. **Explore through the test, never by opening the URL directly** (the seed carries the custom setup):
   `npx playwright test tests/seed.spec.ts --debug=cli` in the background, `attach`, `resume`, then `snapshot`, `click`,
   `eval`. Map the surfaces, journeys, empty and error states, persistence and navigation. Stop the test when done.
4. **Write the spec:** an overview, then groups of scenarios, each with `**Seed:**`, `**File:**
   tests/<group>/<kebab-name>.spec.ts` and numbered user-level steps with `- expect:` bullets for observable outcomes.
   Scenarios are independent and start from the seed; names are kebab-case and match the file name.

   ```markdown
   # <Feature> Test Plan
   ## Application Overview
   <one paragraph>
   ## Test Scenarios
   ### 1. <Group>
   **Seed:** `tests/seed.spec.ts`
   #### 1.1. <kebab-scenario-name>
   **File:** `tests/<group>/<kebab-scenario-name>.spec.ts`
   **Steps:**
     1. <concrete user step>
       - expect: <observable outcome>
   ```

## Generate

For each target scenario, one at a time (they share the seed session): start the seed in debug mode in the background,
`attach`, `resume`, walk the steps with `playwright-cli`, treat the live app as the truth and update the spec when a step is
vague or stale. Write one test per file at the spec's path, with a `// spec:` and `// seed:` header, the group name as
`test.describe`, a `// N. step text` comment before each step's actions, and an assertion per `- expect:`. Import from
`./fixtures` when the project has one. Close the session and stop the background test before the next scenario, then run
the new test once.

```ts
// spec: specs/basic-operations.plan.md
// seed: tests/seed.spec.ts
import { test, expect } from './fixtures';
test.describe('Signing in and out', () => {
  test('should sign in', async ({ page }) => {
    // 2. Type 'John Doe' into the username field
    await page.getByRole('textbox', { name: 'username' }).fill('John Doe');
    await expect(page.getByRole('heading')).toContainText('Welcome, John Doe!');
  });
});
```

## Heal

Fix failing tests one at a time (shared state, one CLI session):

1. List failures: `PLAYWRIGHT_HTML_OPEN=never npx playwright test`.
2. Debug one with `--debug=cli` and `attach`; check `snapshot`, `console`, `requests`. Common causes: selector drift, a
   wrapper element, a renamed label, timing, an assertion text the app changed, data leaking between runs.
3. Edit the test, stop the background run, rerun the single test.
4. Reconcile with the spec named in the `// spec:` header: a purely technical fix leaves the spec alone; a changed
   user-visible step or outcome updates the spec; if you cannot tell an intentional change from a regression, **stop and
   ask the user** with the scenario id, the stale spec lines and the observed behaviour.
5. Only when the test is right, the app is wrong and the user confirmed the bug: `test.fixme(...)` with a comment naming
   the decision or issue. Never skip silently.

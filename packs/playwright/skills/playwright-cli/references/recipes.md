# Recipes: run-code, request mocking, storage state, sessions

Merged from the old running-code, request-mocking, storage-state and session-management references. Most of it restates
`playwright-cli --help`; what is kept is what `--help` does not show.

## `run-code`

`run-code` runs one async function expression against the page: `playwright-cli run-code "async page => { ... }"` or
`run-code --filename=script.js`. It is wrapped in `(...)` and evaluated, so no `import`, `export` or `require`. Whatever it
returns is printed.

```bash
playwright-cli run-code "async page => {
  await page.context().grantPermissions(['geolocation']);
  await page.context().setGeolocation({ latitude: 51.5074, longitude: -0.1278 });
}"
playwright-cli run-code "async page => { await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' }); }"
playwright-cli run-code "async page => { await page.locator('.loading').waitFor({ state: 'hidden' }); }"
playwright-cli run-code "async page => { const f = page.locator('iframe#x').contentFrame(); await f.locator('button').click(); }"
playwright-cli run-code "async page => {
  const d = page.waitForEvent('download');
  await page.getByRole('link', { name: 'Download' }).click();
  const download = await d; await download.saveAs('./out.pdf'); return download.suggestedFilename();
}"
```

Grant `clipboard-read` before reading `navigator.clipboard`. Wrap a step in `try/catch` and return a string when you want a
soft failure. Prefer waiting on an element or a URL over `networkidle`.

## Request mocking

```bash
playwright-cli route "**/*.jpg" --status=404
playwright-cli route "**/api/users" --body='[{"id":1}]' --content-type=application/json --header="X-Custom: v"
playwright-cli route "**/*" --remove-header=cookie,authorization
playwright-cli route-list ; playwright-cli unroute "**/*.jpg" ; playwright-cli unroute     # last one clears all
```

Patterns: `**/api/users` (path), `**/api/*/details` (wildcard), `**/*.{png,jpg}` (extensions), `**/search?q=*` (query).
For conditional replies, request-body checks, response edits, failures or delays use `run-code`:

```bash
playwright-cli run-code "async page => {
  await page.route('**/api/user', async route => {
    const response = await route.fetch(); const json = await response.json();
    json.isPremium = true; await route.fulfill({ response, json });
  });
  await page.route('**/api/offline', route => route.abort('internetdisconnected'));
}"
```

`route.abort` reasons: `connectionrefused`, `timedout`, `connectionreset`, `internetdisconnected`.

## Storage state

```bash
playwright-cli state-save auth.json ; playwright-cli state-load auth.json     # cookies + localStorage, reload the page after
playwright-cli cookie-list --domain=example.com ; playwright-cli cookie-set session abc --domain=example.com --httpOnly --secure
playwright-cli localstorage-set theme dark ; playwright-cli sessionstorage-get step
```

`state-save` writes real session cookies: keep the file out of git (`.gitignore`) and never paste its contents. For several
cookies or IndexedDB (`indexedDB.databases()`, `deleteDatabase`) use `run-code` with `context().addCookies([...])` or
`page.evaluate`. Reusing auth: log in once, `state-save auth.json`, later `state-load auth.json` and open the dashboard.

## Sessions

```bash
playwright-cli -s=auth open <url> --persistent     # a named, isolated session: own cookies, storage, cache, tabs
playwright-cli -s=public snapshot ; playwright-cli list ; playwright-cli close-all ; playwright-cli kill-all
playwright-cli -s=auth delete-data                 # drop a persistent profile
export PLAYWRIGHT_CLI_SESSION=mysession            # default session name for the shell
```

Profiles are in memory unless you pass `--persistent` or `--profile=DIR`. Attach to a running browser with
`attach --cdp=chrome|msedge|<http://localhost:9222>` (the browser needs remote debugging enabled at
`chrome://inspect/#remote-debugging`) or `attach --extension=chrome`; `-s=NAME detach` leaves it running.

## Tracing (three lines)

`playwright-cli tracing-start`, do the steps, `tracing-stop`. A trace holds DOM snapshots, network and console, and is smaller
than video; start it before the problem, not at the failing step, and delete old ones (`.playwright-cli/traces`).

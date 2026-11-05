# Video recording

WebM capture for demos and proof of work. Use a trace (`recipes.md`) for debugging; a video is larger and shows only pixels.

```bash
playwright-cli open <url>
playwright-cli video-start recordings/login-flow.webm       # a descriptive path
playwright-cli video-chapter "Getting Started" --description="Opening the homepage" --duration=2000
playwright-cli click e1
playwright-cli video-stop
```

## Scripted recording (the part the CLI cannot do)

For a video you hand to a person, drive it from one `run-code` script so you control pauses, typing speed and
annotations. First do the scenario once with the CLI to note the locators, then:

```js
async page => {
  await page.screencast.start({ path: 'video.webm', size: { width: 1280, height: 800 } });
  await page.goto('<url>');
  await page.screencast.showChapter('Adding items', { description: 'Add two items.', duration: 2000 });
  const box = page.getByRole('textbox', { name: 'What needs to be done?' });
  await box.pressSequentially('Walk the dog', { delay: 60 });   // readable typing
  await box.press('Enter');
  const note = await page.screencast.showOverlay('<div style="position:absolute;top:8px;right:8px;padding:6px 12px;background:rgba(0,0,0,.7);color:#fff;border-radius:8px">Item added</div>');
  await page.waitForTimeout(1500);
  await note.dispose();                                         // a sticky overlay stays until disposed
  await page.screencast.stop();
}
```

Run it with `playwright-cli run-code --filename=script.js`.

- Overlays are `pointer-events: none`, so a sticky one never blocks a click.
- API: `showChapter(title, { description?, duration? })` blurs the page for a card; `showOverlay(html, { duration? })` draws
  a callout or a highlight (position it from `locator.boundingBox()`); `hideOverlays()` and `showOverlays()` toggle all.
- Recording adds overhead and large files; delete recordings you no longer need.

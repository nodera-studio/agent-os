# Pack: sentry-cli (release plumbing versus runtime debugging)

Project-specific guidance for Sentry: `sentry-cli` for release, sourcemap and deploy work (headless and CI), the Sentry
MCP for looking up a live issue and running Seer. The old skill pinned a `sentry-cli` version that went stale; the pin is
gone, so check `sentry-cli --version` against your own release process.

```bash
./install.sh <target> --pack sentry-cli
```

Ships `skills/sentry-cli/SKILL.md` only. Install it in projects that report to Sentry.

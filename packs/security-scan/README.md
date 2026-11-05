# Pack: security-scan (quarantined: broken as shipped)

**Do not install this pack expecting it to work.** It is parked here because `/security-scan` could not run in core:
the command calls files that exist nowhere in this tree or in the upstream repository.

```bash
./install.sh <target> --pack security-scan   # installs the command and the writeup only
```

## What it ships

| File | Role |
| --- | --- |
| `commands/security-scan.md` | Runs a config-security scan of `.claude/`, hooks and MCP setup (AgentShield static scan plus an advisory `mcp-scan`) and summarises it |
| `docs/config-security.md` | The residual-risk writeup for the widened-autonomy posture the scan watches |

## Missing dependencies

The command and the writeup need all of these, and none of them ships here:

- `scripts/security-scan.sh`: the wrapper the command runs (`bash scripts/security-scan.sh [min-severity]`).
- `.agentshield/baseline.json` and `.agentshield.json`: the committed accepted-findings baseline and the scanner config.
- `.github/workflows/config-security.yml`: the CI gate the command's last paragraph describes.
- `ecc-agentshield` (an npm package, run with `npx`) and, optionally, `uvx` or `uv` for Invariant `mcp-scan`.

To make it work, write the wrapper and generate the baseline
(`npx ecc-agentshield scan --path . --save-baseline .agentshield/baseline.json`), confirm the installed version's flags
(`docs/config-security.md` says versions differ), then move the files into core or keep them as a project pack.
Until then the command fails on its first step. Report-only by design: it must never apply `--fix`, edit
`.claude/settings.local.json`, or re-add `permissions.deny` for `.env`, secrets or MCP.

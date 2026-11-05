# Packs

Optional bundles of agents, commands, skills, hooks and scripts that the core install does not carry.
`install.sh` reads them from this directory in the harness checkout; the target project only ever receives
the files a pack lists. `packs/` itself is not copied into the target.

```bash
./install.sh --list-packs [<target>]            # name, install state, description
./install.sh <target> --pack NAME [--pack NAME] # plain install first, then the packs, in the order given
./install.sh <target> --remove-pack NAME        # no plain install; removes only what the manifest says is unchanged
```

## Core routing defaults and packs

`routing.json` is seeded once by the plain install and is never overwritten, and a pack's `routing` fragment only
fills keys that are unset. So neither a re-install nor a pack changes the review, planning, debug and audit
roster of a project that already has a `routing.json`. To adopt a newer release's defaults, copy the changed keys
by hand (see "Adopting new routing defaults" in the root README). The `codex` pack adds native Codex as an opt-in
tool; it does not put Codex back into the default roster (`omp_fallback` stays empty).

## Layout

```text
packs/<name>/
  pack.json
  agents/ commands/ skills/ hooks/ scripts/ rules/ docs/ omp/ prompts/ templates/   (only what the pack ships)
```

A file `packs/<name>/hooks/x.sh` is installed to `<target>/.claude/hooks/x.sh`.

## `pack.json`

```json
{
  "name": "example",
  "version": "1",
  "description": "One line shown by --list-packs.",
  "files": ["agents/example/agent.md", "hooks/example.sh"],
  "hooks": [
    { "event": "PreToolUse", "matcher": "Bash", "command": ".claude/hooks/example.sh", "timeout": 10 }
  ],
  "routing": { "example_key": ["claude"] },
  "requires": ["pack:other", "cmd:node"],
  "prior_hashes": { "hooks/example.sh": ["<sha256 of an earlier shipped version>"] }
}
```

| Key | Meaning |
| --- | --- |
| `name` | Must equal the directory name. Lower-case letters, digits, `-` and `_`. |
| `files` | Required. Paths relative to the pack directory. The first directory must be one of `agents commands skills hooks scripts rules docs omp prompts templates`; no absolute paths, no `..`, no symlinks. Every listed file must exist. |
| `hooks` | Optional. `event`, `command`, optional `matcher` and `timeout`. Merged into `<target>/.claude/settings.json`. |
| `routing` | Optional. Top-level keys merged into `<target>/.claude/routing.json` only when the key is unset there. |
| `requires` | Optional. `pack:<name>` needs that pack installed (or earlier in the same call); anything else (`cmd:<tool>` or a bare tool name) must be on `PATH`. Checked before anything is copied. |
| `prior_hashes` | Optional. Known sha256 values of earlier shipped versions of a file, per path. They let an upgrade replace a file from a pre-manifest install. |

## Ownership manifest

`<target>/.claude/packs.lock.json` (written by `install.sh`, never by hand) records, per pack, the sha256 of
every file it installed, the hook entries it added (and whether it added them or found them already wired) and the
routing keys it set. It carries no timestamps, so running the same command twice leaves it byte-identical.

| Situation | What `install.sh` does |
| --- | --- |
| Destination missing | Copy it and record the hash. |
| In the manifest and unchanged since install | Replace it when the pack file changed. |
| In the manifest but edited since install | Keep it, report `CONFLICT modified`. |
| Not in the manifest, same content as the pack file | Adopt it (record the hash). |
| Not in the manifest, hash is in `prior_hashes` | Replace it (a pre-manifest install of a known version). |
| Not in the manifest, any other content | Keep it, report `CONFLICT ambiguous-ownership`. |
| Removal and the file is unchanged | Delete it, then any directory it leaves empty (never a top-level one). |
| Removal and the file is edited | Keep it, report `CONFLICT modified`; the pack stays in the manifest as `partial` until a later `--remove-pack` finds nothing left. |

`settings.json` is seeded once and is yours afterwards. A pack merge only adds hook entries, deduped by command
(a command already wired anywhere under the same event is left alone and recorded as not added), writes through
a temporary file validated with `jq`, and does nothing when the result is unchanged. Removal deletes only the
entries the pack added. A `settings.json` that is missing or has an unexpected shape is reported as a conflict
and left untouched.

There is no `rsync --delete` anywhere in the installer. Exit codes: `0` ok, `1` error (unknown or invalid pack,
missing requirement, unusable manifest, plugin links that do not resolve), `3` finished with conflicts.

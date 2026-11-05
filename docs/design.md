# omp engine design notes

Internals of the read-only omp engines (`scripts/omp-engine.sh`), moved out of `skills/omp/SKILL.md` so the
skill stays a short dispatch guide. Read this when changing the sandbox, the policy or the launchers.
The profiles are listed in `omp/profiles.sh` (`glen-harness-codex`, `glen-harness-opencode`); where the
text below says `glen-harness` it means the engine's profile, and where it says the provider it means
`openai-codex` or `opencode-go`.

## What is enforced

The policy overlay sets `tools.approvalMode: always-ask` and per-tool deny/allow rules.
Writes fail closed in headless approval because glen passes `--no-ui`. Reads are contained
by `fetch.enabled: false`, `web_search.enabled: false`, and `tools.restrictedFolders: ["~"]`.
Mnemosyne memory is read-only; every memory call uses `project: "{{PROJECT_NAME}}"`.

Dispatch scrubs `CLAUDE_CONFIG_DIR`, `PI_PY`, `PI_JS`, `PI_CODING_AGENT_DIR`,
`OMP_CODING_AGENT_DIR`, `OMP_PROFILE`, `PI_PROFILE`, and the four `XDG_*_HOME` variables (which
would move sessions and leases away from the `~/.omp` layout the sandbox grants). It sets a private `GLEN_HOME`,
the captured policy's absolute `PI_CONFIG_FILES`, and the job deadline. The Mnemosyne token
passes through untouched; never print its value or any other environment values.

The engine sees a snapshot outside HOME, without Git metadata. Root agent configuration
is relocated to `_agent-config/` (for example `.claude/` becomes `_agent-config/claude/`).
Policy comes from `main` when available, with a warned worktree fallback. The snapshot's
source fingerprint leads with the commit id (`git rev-parse HEAD`), and the reported `head`
and the merge-base are both taken from that commit, so a clean checkout or reset during
capture is caught like an edit: once during the copy it recaptures, and between the copy and
the diff capture the run skips with `source changed during capture`.

The glen-harness profile must not be relocated. If any component from the omp root
(`~/.omp`, or `$HOME/$PI_CONFIG_DIR`) down through `profiles/glen-harness/agent`, or one of
its writable children (`agent/sessions`, `logs`, `cache`, `run`, `run/daemons`, the shared
`run` and `run/session-owners`), is a symlink, launcher resolution, probe and dispatch refuse
with `refusing symlinked glen-harness profile path: <path>`; the sandbox launcher refuses
the same for the four profile components. Setup replaces the profile's
`mcp.json` only when its bytes are exactly a template version setup shipped; any other
difference (an added server or key, an edited URL, default, header or token) is a conflict
that leaves the file alone.

## Best-effort Claude Code deny rules

`.claude/settings.json` denies literal command prefixes such as `omp login` in Claude's
own typed Bash calls. These are courtesy guardrails, not a security boundary or a sound
shell parser: do not rely on them to catch `bash -c "omp login"`, heredocs, variable
indirection, or other alternate invocation forms. They do not govern calls inside scripts.
[Claude Code also checks separated subcommands and unwraps some wrappers](https://code.claude.com/docs/en/permissions#compound-commands);
prefix matching is not limited to position zero of the entire Bash call.
The real default-profile protections are explicit `--profile glen-harness` on every
harness invocation, setup's default-profile fingerprint, and the OS sandbox.

## Risks

The macOS `sandbox-exec` launcher contains reads of other processes' sibling directories
under `$TMPDIR`; containment does not rely solely on file permissions. Any omp invocation
can write shared, cross-profile state in `~/.omp/natives/` and `~/.omp/run/`; the
default-profile fingerprint excludes both. Inside the sandbox only `~/.omp/run/session-owners`
(lease files, under `$HOME/$PI_CONFIG_DIR` when that is set) is readable and writable, and its
lease files can be created and locked but never removed or replaced; `~/.omp/run/daemons` (broker tokens and launch specs
that an unsandboxed broker trusts) is neither, and of the harness profile's own `run/daemons`
only this run's presence directory is. That scope is hashed by the resolved omp
binary, whatever its file name, bounded to 10 seconds (`timeout`, or a perl alarm); when it
cannot be derived, the launcher warns, naming the binary. The native cache is read-only at
`~/.omp/natives` (omp 18.14.0's addon loader always uses it) and, for an alternate config
root, at `$HOME/$PI_CONFIG_DIR/natives` too. The launcher creates the runtime
directories the policy protects (`agent/sessions`, `logs`, `cache`, `run`, that scope, and
`session-owners`) before it starts omp, refusing symlinks, and points `TMPDIR` at the run
root's private `tmp/`. A sandboxed child cannot rename or remove another harness session's
directory, but it can still delete individual session files in it: omp itself replaces
session files by rename, so a file-level deny would break it. That residual is limited to
the harness profile's transcripts. Three more residuals are accepted:
`session-owners` is shared by every profile, so the child can list the session ids of every
profile's leases and hold an existing lease open (flock needs only an open file), and entries
it creates there cannot be removed by it; the profile's own `run/` (`tiny`, `mnemopi`,
`provider-inflight`) stays writable outside `run/daemons`, so a forged lease there could stall
later harness-profile provider calls; and the source fingerprint hashes each untracked,
non-ignored file separately, about 14 ms per file per pass (three passes per dispatch). Setup's `--dry-run` makes no config changes, but
querying config still initializes databases and caches on disk under `glen-harness`.

**The engine is unavailable on Linux in v0.1.0.** bwrap cannot isolate abstract Unix sockets
while still letting the sandboxed process reach the provider over the network, so there is no safe
bwrap policy today. `probe` returns `unavailable: linux abstract-socket isolation not
supported` and dispatch never runs or calls `omp-sandboxed-linux.sh`. That launcher stays in
the repo for a later Landlock-based version.

**Outbound network is restricted to TCP port 443, the Mnemosyne MCP's own loopback port, and
the mDNSResponder Unix socket**, not to the the provider API host specifically. The
Mnemosyne port is derived at launch from the profile's own `mcp.json` URL field: a loopback host (`localhost`, `127.0.0.1`, or bracketed `[::1]`, any letter case
in scheme and host) on any port is allowed; any other loopback spelling (another `127/8`
address, a long-form or IPv4-mapped IPv6 loopback, `localhost.`) makes the launcher refuse,
naming the supported spellings; a
non-loopback host must already be on 443, or the launcher refuses to start rather than grant it
an unbounded outbound host. Only the URL is parsed; headers and tokens are never read, logged or
carried into the generated profile; when no rule can be derived, the launcher says so on
stderr, without the URL, and Mnemosyne is unreachable for that run. Two residuals remain, accepted by the owner: any HTTPS host
on the public internet is reachable from inside the sandbox (not just the provider's), and `agent.db`
(the the provider credential store) stays readable by the sandboxed omp process, since omp needs it to
authenticate. Neither is mitigated further in v0.1.0.

## Failure handling

Record exit 3 as a skip with its reason. Capacity failures retry once after 60 seconds only
when at least five minutes of the original deadline remain. Exit 5 means timeout; the tree
is retained because the job may still be running. Old runs are pruned after one day.
Malformed output remains in FILE and has `status: "failed", reason: "malformed output"`
in FILE.json, but exits 0 when execution completed cleanly. Give that result no vote.
Never block the whole gate on omp failure; report its absence and continue with other engines.
`GLEN_OMP_ENGINE=off` disables the engine.

A killed run can be recovered from FILE.json as soon as it records `status: "running"`.
A `timeout` result is recoverable only when FILE.json contains a non-null `job` handle;
an interruption before any job handle was obtained is `failed`, not `timeout`.
Use its `glen_home`, `job`, `run_dir`, and deadline with `glen wait`; never re-send.
Apply the same environment scrubbing and policy path when recovering:

```bash
env -u CLAUDE_CONFIG_DIR -u PI_PY -u PI_JS -u PI_CODING_AGENT_DIR \
  -u OMP_CODING_AGENT_DIR -u OMP_PROFILE -u PI_PROFILE \
  GLEN_HOME="<glen_home>" PI_CONFIG_FILES="<run_dir>/policy.yml" GLEN_JOB_TIMEOUT=15m \
  "$GLEN_BIN" wait "<job>" --timeout 60s --json
```


# Skills

A skill is a `SKILL.md` with YAML frontmatter (`name`, and a `description` that names its triggers) and a body
saying WHEN to use it and HOW. Shipped here:

| Skill | For |
| --- | --- |
| `second-engine` | dispatching a read-only omp engine (`omp:codex`, `omp:opencode`) for a second opinion, review or critique |
| `omp` | the engine mechanics: registry, `omp-engine.sh` modes, exit codes, results, recovery |
| `auto-mode` | the unattended wave loop (`/auto-mode`) and its loop procedures |
| `release-flow` | the staging-trunk / release-branch model and the promote runbook |
| `gh` | the GitHub API surface (`gh`) and the git/gh boundary |
| `exa` | web search and fetch through Exa; versioned library docs go to Context7 |

Mnemosyne ships as a plugin skill, and browser, Linear and Sentry skills ship as opt-in packs. Write your own the
same way: a trigger description specific enough that Claude reaches for it at the right moment, and a body
with the exact commands and conventions for this project.

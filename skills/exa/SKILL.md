---
name: exa
description: >-
  Use the Exa MCP (`web_search_exa`, `web_search_advanced_exa`, `web_fetch_exa`) for web
  access: search the web, find recent articles or docs on a topic, fetch the content of a known URL, or
  check the current online state of a library, tool or company. Trigger on indirect phrasing too ("what's
  the latest on X", "find me sources about Y", "pull up that page"). Boundary: versioned
  LIBRARY/framework/API docs go to Context7 (`/find-docs`), not Exa.
---

# Exa: the web path

Exa is the harness's web path. Check `settings.json` for whether native `WebSearch`/`WebFetch` are denied
in this project (they may be, or not); where they are denied, Exa is the only way to the open web, and
`curl`/`wget` to external hosts is steered off either way. The omp engines have no web access at all, so web
research is always Claude's.

## The three tools

- **`web_search_exa`**: general semantic web search; the default for "find sources on X".
- **`web_search_advanced_exa`**: search with filters (recency, domain include/exclude), when freshness or a
  specific source matters.
- **`web_fetch_exa`**: fetch and extract the content of a **known URL**.

## Web vs Context7

- Versioned library, framework or API docs (React, a CLI's flags) go to **Context7** (`/find-docs`), which is
  version-correct. Not Exa.
- Everything else web (articles, product or company state, standards pages, arbitrary URLs) goes to **Exa**.

## Guardrails

- Exa is the primary engine behind `.claude/agents/research/agent.md` (also `mode: plan`) and `/research`.
- Keep result sets tight: request fewer results and only the fields you need.
- Cite the URLs you act on so claims stay traceable.

---
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Agent, WebFetch, WebSearch
description: Classify PR review comments (human and AI review bots), verify claims, draft responses, apply fixes
argument-hint: [paste review comments after invoking]
model: inherit
---

Read the agent prompt at `.claude/agents/respond-to-review.md` and follow its instructions exactly.

The agent fetches the PR's review comments through the host CLI when it can (human reviewers and AI review
bots such as CodeRabbit and Bugbot, which have their own mode); otherwise ask the user to paste them.

User's input: $ARGUMENTS

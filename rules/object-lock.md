---
# Loaded when a Cloudflare Worker, R2 or D1 configuration is touched.
paths:
  - "**/wrangler.toml"
  - "**/wrangler.json"
  - "**/wrangler.jsonc"
---
Cloudflare Object-Lock rule (kept from the retired wrangler skill; the `cloudflare:wrangler` and
`cf-cli` plugin skills cover the CLI itself):

- Deletes are mutators and stay prompt-gated, never auto-run: `wrangler r2 object delete`,
  `r2_bucket_delete`, and `wrangler d1 ... delete`. Do not add them to an allow list.
- Never bulk-delete a locked object. An Object-Lock posture (indefinite or fixed-duration) is a
  compliance guarantee, not an obstacle to route around.
- Record in the project's own docs which R2 buckets and prefixes are locked and whether the lock
  mode is reversible (dual-key procedure) or a one-way trapdoor.
- Headless and cron Cloudflare work goes through the CLI; the Cloudflare MCP connector is
  read-only account inspection.

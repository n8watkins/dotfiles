---
name: cloudflare-access
description: Use before changing anything in the owner's Cloudflare account through the Cloudflare connector (its execute tool) or wrangler, and before any Cloudflare delete. Covers what agents can reach, what the guard asks about, and the export-before-delete steps for D1, KV and R2.
---

# Cloudflare access

## How agents reach Cloudflare

- **The connector** (Cloudflare MCP plugin): `search` and `docs` find API endpoints, and `execute` runs a JavaScript async function that calls `cloudflare.request({ method, path, query, body })` against the owner's single account.
  It can write to almost everything in the account.
- **wrangler** through Bash, with the project's keys from `pass-env run -- npx wrangler ...`.

Deliberately not granted to the connector: API Tokens, Memberships and Registrar (no access), Billing (read only).
If a task seems to need one of those, stop and ask the owner; do not look for another way in.

## What the guard asks about

`~/.claude/hooks/confirm-cloudflare-delete.sh` reads the code of every `execute` call and asks the owner before it runs when the code:

- sends any DELETE request;
- sets a method that is not one of the literals GET, POST, PUT or PATCH (a variable, a concatenation, a ternary);
- purges a zone's whole cache, sends DROP, DELETE or TRUNCATE to a D1 database, changes R2 lifecycle or lock rules, uploads a Worker whose migrations carry `deleted_classes`, bulk-deletes KV keys, or touches Registrar or API tokens.

For wrangler, `permissions.ask` in `~/.claude/settings.json` asks before every delete, `d1 execute --remote`, `queues purge`, `rollback` and R2 lifecycle change, and dcg blocks Worker, D1 and R2 deletes outright.

Write the method as a plain literal (`method: "GET"`) so the guard can read it; a computed method always asks.
An ask in a background agent is a refusal: report what you wanted to delete and why, and stop.
Never split, rename, encode or move a blocked call to another door (connector to wrangler, or the reverse).

## Before deleting anything

1. Name the exact thing to the owner (account, zone or Worker, resource name and id) and get his word for that specific thing.
   Approval of a plan or a different item does not cover it.
2. Export stored data first, to a file outside the repo (the scratchpad, or a folder the owner names):
   - **D1:** `pass-env run -- npx wrangler d1 export <db> --remote --output <db>-<date>.sql` (add `--table <t>` for one table).
     For a DROP or DELETE, export at least the tables it touches.
     D1 Time Travel can also restore recent history (30 days on paid plans, 7 on free); note the current bookmark with `wrangler d1 time-travel info <db>` before the change.
     It does not bring back a deleted database.
   - **KV:** `pass-env run -- npx wrangler kv key list --namespace-id <id> --remote > keys.json`, turn it into a JSON array of key names, then `pass-env run -- npx wrangler kv bulk get names.json --namespace-id <id> --remote > values.json`.
   - **R2:** list objects with the connector (GET `/accounts/<id>/r2/buckets/<bucket>/objects`, following the cursor), then `pass-env run -- npx wrangler r2 object get <bucket>/<key> --remote --file <path>` for each.
     For a large bucket, ask the owner before copying it all down.
   - **Durable Objects:** there is no export; a `deleted_classes` migration destroys every object's storage.
     Read a project's `migrations` in its wrangler config before deploying it, and treat a new `deleted_classes` entry as a delete.
   - **DNS, Access policies, email routes:** GET the record or policy and save the JSON, so it can be recreated.
3. Say in your report where the export is and how big it is.

## Live sites

Changes to a live site (deploy, rollback, DNS, routes, Access, cache) need the owner's word for that change, even when nothing is deleted.
Prefer a preview deployment or a staging Worker, and say what you changed and how to undo it.

## Rules

- Tell the owner to answer guard prompts with allow once or no, never "don't ask again", which adds an allow rule that removes the guard.
- Never print or commit keys; pipe secrets from the store (`pass-env pipe <entry> -- npx wrangler secret put NAME`).

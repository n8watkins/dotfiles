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

`~/.claude/hooks/confirm-cloudflare-delete.sh` reads calls whose tool name matches `^mcp__.*cloudflare-api__execute$`.
Claude Code asks the owner before running the following code; Codex's `codex-pre-tool-use.py` adapter denies it and tells the agent to report it to the owner:

- sends any DELETE request;
- sets a method it cannot read as GET, POST, PUT or PATCH (a variable it cannot follow to one literal, a call, a getter, a repeated key), or could set one where it does not look (a lone `"DELETE"` string, JSON text, a computed key, `eval`, `Reflect` and similar);
- purges a zone's whole cache, sends destructive SQL to D1 or restores or imports a D1 database, changes R2 lifecycle or lock rules, uploads a Worker whose migrations carry `deleted_classes`, deletes KV keys, DNS records or vectors in bulk, purges a queue, turns off Email Routing, pauses a zone, replaces a whole ruleset phase, list or set of Access policies, rotates a Turnstile secret, touches Registrar or API tokens, or sends email.

For wrangler, `permissions.ask` in `~/.claude/settings.json` asks before every `... delete`, `d1 execute --remote`, `d1 time-travel restore`, `queues purge`, `rollback` and R2 lifecycle or lock change, `confirm-destructive-git.sh` asks before a deploy that adds a `deleted_classes` migration, and dcg blocks Worker, D1 and R2 deletes outright.

Write the method as a plain literal (`method: "GET"`) so the guard can read it.
A constant, a concatenation or a ternary of literals is read too; anything it cannot follow asks.
In Claude Code, when the guard asks from a subagent, the prompt goes to the owner's main session and the call waits for his answer.
In a headless run (`claude -p`, no one to answer) the ask becomes a refusal: report what you wanted to change and why, and stop.
In Codex, the adapter returns a denial rather than opening a confirmation prompt, including in interactive sessions.
The owner must review and trust the hook through `/hooks` before it runs.
The adapter also accepts Codex's normalized `cloudflare_api__execute` suffix and passes it to the same parser.
After a denial, report the exact operation and reason and wait for the owner's instructions; approval in chat does not disable the guard or authorize changing tools to get around it.
An owner can perform an approved operation themselves, after the required export, and have the agent verify it with a read-only call.
This matcher does not cover a different connector's tool names or arbitrary HTTP clients; do not assume those paths have equivalent enforcement.
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

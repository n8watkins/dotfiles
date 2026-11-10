#!/usr/bin/env bash
# Tests for dcg with this repo's config, allowlist and n8 pack, through the same
# path Claude Code uses: a PreToolUse payload on stdin, in bypass mode.
# Run: home/.config/dcg/packs/n8.test.sh   (needs dcg on PATH or DCG_BIN)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)" # home/.config/dcg
dcg="${DCG_BIN:-$(command -v dcg)}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/dcg/packs"
sed "s#~/.config/dcg/packs/\*.yaml#$here/packs/*.yaml#" "$here/config.toml" >"$tmp/dcg/config.toml"
cp "$here/allowlist.toml" "$tmp/dcg/allowlist.toml"
export XDG_CONFIG_HOME="$tmp" DCG_CONFIG="$tmp/dcg/config.toml" DCG_HISTORY_DISABLED=1 HOME="$tmp"

"$dcg" pack validate "$here/packs/n8.yaml" >/dev/null 2>&1 || { echo "FAIL: n8.yaml does not validate"; exit 1; }

fail=0 n=0
decide() { # decide <tool> <command> -> deny | allow
  local out
  out="$(jq -nc --arg t "$1" --arg c "$2" '{session_id:"test",cwd:"/home/u/p",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{command:$c},tool_use_id:"t1",permission_mode:"bypassPermissions"}' |
    "$dcg" 2>/dev/null)" || true
  if [ -n "$out" ] && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')" = deny ]; then
    echo deny
  else
    echo allow
  fi
}
expect() { # expect deny|allow <command>
  n=$((n + 1))
  local got; got="$(decide Bash "$2")"
  if [ "$got" != "$1" ]; then fail=$((fail + 1)); echo "FAIL: expected $1, got $got: $2"; fi
}

# n8 pack: D1.
expect deny  'npx wrangler d1 execute app-db --remote --command "DROP TABLE users"'
expect deny  'npx wrangler d1 execute app-db --remote --command "DELETE FROM users"'
expect deny  'npx wrangler d1 execute app-db --remote --command "delete from users where id = 1"'
expect deny  'wrangler d1 execute app-db --command="TRUNCATE users"'
expect deny  'npx wrangler d1 execute app-db --remote --file ./scripts/cleanup.sql'
expect deny  'npx wrangler d1 time-travel restore app-db --timestamp 1731100000'
expect allow 'npx wrangler d1 execute app-db --local --command "DELETE FROM users"'
expect allow 'npx wrangler d1 execute app-db --remote --command "SELECT count(*) FROM users"'
expect allow 'npx wrangler d1 execute app-db --local --file ./seed.sql'
expect allow 'npx wrangler d1 migrations apply app-db --remote'
expect allow 'npx wrangler d1 time-travel info app-db'
# dcg's own packs, enabled in config.toml.
expect deny  'npx wrangler d1 delete app-db'
expect deny  'wrangler r2 bucket delete uploads'
expect deny  'npx wrangler delete'
expect deny  'supabase db reset'
# Turso.
expect deny  'turso db shell app-db "DROP TABLE users"'
expect deny  "turso db shell app-db 'delete from sessions'"
expect deny  'turso db shell app-db < wipe.sql'
expect deny  'turso db destroy app-db'
expect deny  'turso db destroy app-db --yes'
expect deny  'turso group destroy default'
expect allow 'turso db shell app-db "SELECT * FROM users LIMIT 5"'
expect allow 'turso db list'
expect allow 'turso db create app-db-preview'
# Drizzle and Prisma.
expect deny  'npx drizzle-kit push'
expect deny  'pnpm drizzle-kit push --force'
expect deny  'npx drizzle-kit drop'
expect deny  'npx prisma migrate reset --force'
expect deny  'npx prisma db push --force-reset'
expect deny  'npx prisma db push --accept-data-loss'
expect allow 'npx drizzle-kit generate'
expect allow 'npx drizzle-kit migrate'
expect allow 'npx prisma migrate deploy'
expect allow 'npx prisma generate'
expect allow 'npx prisma db push'
# Vercel.
expect deny  'vercel remove my-app --yes'
expect deny  'vercel rm my-app'
expect deny  'vercel project rm my-app'
expect deny  'vercel env rm DATABASE_URL production'
expect deny  'vercel domains rm example.com'
expect allow 'vercel deploy --prod'
expect allow 'vercel env ls'
expect allow 'vercel ls'
# An agent may not lift a block itself.
expect deny  'dcg allow-once 123456'
expect deny  'dcg allowlist add core.git:reset-hard -r because'
expect deny  'dcg uninstall'
expect deny  'agent-lock approve'
expect allow 'agent-lock check'
expect allow 'dcg test "git status"'
expect allow 'dcg explain -- "git status"'
# Wrappers and chains are seen through.
expect deny  'cd app && npx drizzle-kit push'
expect deny  'bash -c "turso db destroy app-db"'
expect deny  'sudo vercel remove my-app'
# Text that only mentions a command does not run it.
expect allow 'git commit -m "docs: never run drizzle-kit push or turso db destroy"'
expect allow 'gh pr create --title "x" --body "blocks vercel remove and DROP TABLE"'
expect allow 'grep -rn "drizzle-kit push" docs/'
# Core packs, with the allowlist.
expect deny  'git reset --hard'
expect deny  'git push origin main --force'
expect deny  'rm -rf ~/projects/app'
expect deny  'rm -rf src'
expect allow 'git branch -D feat/old-branch'
expect allow 'rm -rf node_modules'
expect allow 'rm -rf ./dist .next'
expect allow 'rm -rf /tmp/claude-1000/scratch/build'
# GitHub: the deletes the owner confirms are left to settings.json ask rules
# and confirm-destructive-git.sh; dcg blocks the rest.
expect allow 'gh repo delete n8watkins/app --yes'
expect allow 'gh repo archive n8watkins/app --yes'
expect allow 'gh secret delete API_KEY -R n8watkins/app'
expect allow 'gh api -X DELETE repos/n8watkins/app/git/refs/heads/feat/old'
expect allow 'gh api repos/n8watkins/app/git/refs/heads/feat-old --method DELETE'
expect allow 'gh run cancel 123'
expect deny  'gh api -X DELETE repos/n8watkins/app'
expect deny  'gh api -X DELETE repos/n8watkins/app/releases/1'
expect deny  'gh api -X DELETE repos/n8watkins/app/git/refs/heads/x; gh api -X DELETE repos/n8watkins/app'
expect deny  'gh release delete v1.0.0 --yes'
expect deny  'npm unpublish my-package@1.0.0'
# Everyday commands stay allowed.
expect allow 'git status'
expect allow 'npm run build'
expect allow 'git push -u origin feat/x'

# Codex gets the same decision (dcg detects it from turn_id).
n=$((n + 1))
out="$(jq -nc '{session_id:"s",turn_id:"turn-1",cwd:"/home/u/p",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"turso db destroy app-db"},tool_use_id:"t1"}' | "$dcg" 2>/dev/null || true)"
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')" != deny ]; then
  fail=$((fail + 1)); echo "FAIL: Codex payload not denied"
fi
# The denial tells the agent to ask the owner.
n=$((n + 1))
reason="$(jq -nc '{session_id:"s",cwd:"/",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"npx drizzle-kit push"},tool_use_id:"t1",permission_mode:"bypassPermissions"}' | "$dcg" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$reason" in *"ask the owner"*) ;; *) fail=$((fail + 1)); echo "FAIL: denial does not tell the agent to ask the owner";; esac

echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]

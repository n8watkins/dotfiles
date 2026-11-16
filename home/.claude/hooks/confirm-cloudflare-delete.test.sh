#!/usr/bin/env bash
# Tests for confirm-cloudflare-delete.sh. Run: bash home/.claude/hooks/confirm-cloudflare-delete.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
hook="$here/confirm-cloudflare-delete.sh"
# The Python sits inside a single-quoted bash string: a stray single quote in it
# ends the string early and the hook breaks in ways cases may not show.
if sed -n '/^exec python3 -I -c /,/^. "\$input"$/p' "$hook" | sed '1d;$d' | grep -n "'"; then
  echo "FAIL: a single quote inside the hook's Python (use \\x27)"; exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

TOOL=mcp__plugin_cloudflare_cloudflare-api__execute
fail=0
cases=0
check() { # expect(ask|allow) payload [text the reason must contain]
  local expect=$1 payload=$2 want=${3:-} out got
  cases=$((cases + 1))
  out=$(printf '%s' "$payload" | "$hook" 2>"$tmp/stderr")
  if [ -s "$tmp/stderr" ]; then
    printf 'FAIL (hook error: %s): %s\n' "$(cat "$tmp/stderr")" "$payload"
    fail=1
  fi
  if printf '%s' "$out" | grep -q '"permissionDecision": "ask"'; then got=ask; else got=allow; fi
  if [ "$got" != "$expect" ]; then
    printf 'FAIL (expected %s, got %s): %s\n' "$expect" "$got" "$payload"
    fail=1
  elif [ "$got" = allow ] && [ -n "$out" ]; then
    printf 'FAIL (allow must be silent, printed %s): %s\n' "$out" "$payload"
    fail=1
  elif [ -n "$want" ] && ! printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -qF -- "$want"; then
    printf 'FAIL (reason lacks "%s": %s): %s\n' "$want" "$out" "$payload"
    fail=1
  fi
}
run() { # expect(ask|allow) code [reason text] [tool name]
  check "$1" "$(jq -n --arg c "$2" --arg t "${4:-$TOOL}" \
    '{tool_name:$t,tool_input:{code:$c},permission_mode:"default",hook_event_name:"PreToolUse"}')" "${3:-}"
}

# GET only, and writes that are not on the list, pass silently.
run allow 'async () => cloudflare.request({ method: "GET", path: `/accounts/${accountId}/workers/scripts` })'
run allow 'async () => { const r = await cloudflare.request({ path: "/zones" }); return r.result; }'
run allow 'async () => cloudflare.request({ method: "GET", path: "/accounts/x/workers/scripts/delete-me" })'
run allow 'async () => cloudflare.request({ method: "PUT", path: "/accounts/x/workers/scripts/my-worker", body: { main_module: "index.js" } })'
run allow 'async () => cloudflare.request({ method: "POST", path: "/accounts/x/storage/kv/namespaces", body: { title: "cache", delete: false } })'
run allow 'async () => cloudflare.request({ method: "PATCH", path: "/zones/z/settings/ssl", body: { value: "strict", note: "do not delete" } })'
run allow $'async () => {\n  // await cloudflare.request({ method: "DELETE", path: "/zones/z/dns_records/1" })\n  /* method: "DELETE" */\n  return cloudflare.request({ method: "GET", path: "/zones/z/dns_records" });\n}'
run allow 'async () => cloudflare.request({ method: "POST", path: "/zones/z/purge_cache", body: { files: ["https://n8builds.dev/a.css"] } })'
run allow 'async () => cloudflare.request({ method: "POST", path: "/accounts/a/d1/database/d/query", body: { sql: "SELECT * FROM users WHERE deleted = 0" } })'
run allow 'async () => cloudflare.request({ method: "GET", path: "/accounts/a/r2/buckets/b/lifecycle" })'
run allow 'async () => { const r = await cloudflare.request({ path: "/accounts/a/workers/scripts" }); return r.result.filter((s) => /delete|old/i.test(s.id)); }'
run allow 'async () => { const req = { method: "GET", path: "/zones" }; if (req.method === "DELETE") throw new Error("no"); return cloudflare.request(req); }'

# A literal DELETE in each quoting style and case asks, naming the path.
run ask 'async () => cloudflare.request({ method: "DELETE", path: "/accounts/a/workers/scripts/old-worker" })' 'DELETE to /accounts/a/workers/scripts/old-worker'
run ask "async () => cloudflare.request({ method: 'delete', path: '/zones/z/dns_records/r1' })" 'DELETE to /zones/z/dns_records/r1'
run ask 'async () => cloudflare.request({ method: `Delete`, path: `/accounts/${a}/storage/kv/namespaces/${ns}` })' 'DELETE to /accounts/${a}/storage/kv/namespaces/${ns}'
run ask 'async () => cloudflare.request({ "method": "DeLeTe", "path": "/accounts/a/r2/buckets/b" })' 'DELETE to /accounts/a/r2/buckets/b'
run ask 'async () => cloudflare.request({ path: "/zones/z/dns_records/r1", method: " DELETE " })' 'DELETE to /zones/z/dns_records/r1'
# DELETE in a loop over paths.
run ask $'async () => {\n  for (const id of ["r1", "r2"]) {\n    await cloudflare.request({ method: "DELETE", path: `/zones/z/dns_records/${id}` });\n  }\n}' 'DELETE to /zones/z/dns_records/${id}'
run ask 'async () => Promise.all(paths.map((p) => cloudflare.request({ method: "DELETE", path: p })))' 'a path the guard could not read'
# A method the hook cannot read as a safe literal asks.
run ask 'async () => { const m = "DELETE"; return cloudflare.request({ method: m, path: "/zones/z" }); }' 'method could not be read'
run ask 'async () => cloudflare.request({ method: "DEL" + "ETE", path: "/zones/z" })' 'method could not be read'
run ask 'async () => cloudflare.request({ method: ["DE", "LETE"].join(""), path: "/zones/z" })' 'method could not be read'
run ask 'async () => cloudflare.request({ method: dryRun ? "GET" : "DELETE", path: "/zones/z" })' 'method could not be read'
run ask 'async () => cloudflare.request({ method: `${verb}`, path: "/zones/z" })' 'method could not be read'
run ask 'async () => { const method = pick(); return cloudflare.request({ method, path: "/zones/z" }); }' 'method could not be read'
run ask 'async () => cloudflare.request({ method: "HEAD", path: "/zones/z" })' 'method could not be read'
run ask 'async () => { const req = { path: "/zones/z/dns_records/r1" }; req.method = "DELETE"; return cloudflare.request(req); }' 'DELETE'
run ask 'async () => { const req = { path: "/zones/z" }; req["method"] = verb; return cloudflare.request(req); }' 'method could not be read'
run ask 'async () => `${await cloudflare.request({ method: "DELETE", path: "/zones/z" })}`' 'DELETE to /zones/z'

# The listed non-DELETE calls that destroy data ask.
run ask 'async () => cloudflare.request({ method: "POST", path: "/zones/z/purge_cache", body: { purge_everything: true } })' 'purges the whole cache'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/d1/database/${db}/query`, body: { sql: "DROP TABLE users" } })' 'D1'
run ask 'async () => cloudflare.request({ method: "POST", path: "/accounts/a/d1/database/d/raw", body: { sql: "delete from sessions" } })' 'D1'
run ask 'async () => cloudflare.request({ method: "POST", path: "/accounts/a/d1/database/d/query", body: { sql: "Truncate t" } })' 'D1'
run ask 'async () => cloudflare.request({ method: "PUT", path: "/accounts/a/r2/buckets/b/lifecycle", body: { rules: [] } })' 'lifecycle'
run ask 'async () => cloudflare.request({ method: "PUT", path: "/accounts/a/r2/buckets/b/lock", body: { rules: [] } })' 'lock rules'
run ask 'async () => cloudflare.request({ method: "POST", path: "/accounts/a/storage/kv/namespaces/n/bulk/delete", body: ["k1", "k2"] })' 'KV keys in bulk'
run ask 'async () => cloudflare.request({ method: "PUT", path: `/accounts/${a}/workers/scripts/rooms`, body: { metadata: { migrations: { new_tag: "v3", deleted_classes: ["Room"] } } } })' 'Durable Object class'
run allow 'async () => cloudflare.request({ method: "PUT", path: `/accounts/${a}/workers/scripts/rooms`, body: { metadata: { migrations: { new_tag: "v3", new_sqlite_classes: ["Room"] } } } })'
run ask 'async () => cloudflare.request({ method: "PUT", path: "/accounts/a/registrar/domains/n8builds.dev", body: { auto_renew: false } })' 'Registrar'
run ask 'async () => cloudflare.request({ method: "POST", path: "/user/tokens", body: { name: "x" } })' 'API token'
run ask 'async () => cloudflare.request({ method: "PUT", path: "/accounts/a/tokens/t1/value", body: {} })' 'API token'
run ask 'async () => { const p = "/zones/z/purge_cache"; return cloudflare.request({ method: "POST", path: p, body: { purge_everything: true } }); }' 'purges the whole cache'

# Unreadable or malformed input asks; other tools are ignored.
run ask 'async () => cloudflare.request({ method: "GET", path: "/zones/z })' 'could not read'
run ask 'async () => { /* unclosed comment ' 'could not read'
check ask 'not json at all' 'could not read'
check ask '' 'could not read'
check ask "{\"tool_name\":\"$TOOL\",\"tool_input\":{}}" 'could not find the code'
check ask "{\"tool_name\":\"$TOOL\",\"tool_input\":{\"code\":42}}" 'could not find the code'
run ask 'async () => cloudflare.request({ method: "DELETE", path: "/zones/z" })' 'DELETE to /zones/z' 'mcp__claude_ai_Cloudflare__cloudflare-api__execute'
run allow 'async () => cloudflare.request({ method: "DELETE", path: "/zones/z" })' '' 'mcp__plugin_cloudflare_cloudflare-api__search'
run allow 'async () => cloudflare.request({ method: "DELETE", path: "/zones/z" })' '' 'mcp__other__execute'
check allow '{"tool_name":"Bash","tool_input":{"command":"wrangler delete"}}'
check allow '{"tool_name":"mcp__plugin_cloudflare_cloudflare-api__execute_more","tool_input":{"code":"async () => cloudflare.request({ method: \"DELETE\", path: \"/x\" })"}}'

# Speed: well under 100 ms per call on a large script (python start included).
big=$(for i in $(seq 1 300); do printf 'await cloudflare.request({ method: "GET", path: `/zones/%s/dns_records`, query: { page: %s } });\n' "$i" "$i"; done)
payload=$(jq -n --arg c "async () => { $big }" --arg t "$TOOL" '{tool_name:$t,tool_input:{code:$c}}')
start=$(date +%s%N)
for _ in 1 2 3 4 5; do printf '%s' "$payload" | "$hook" >/dev/null; done
ms=$(( ($(date +%s%N) - start) / 5000000 ))
cases=$((cases + 1))
if [ "$ms" -ge 100 ]; then echo "FAIL (slow: ${ms} ms per call on a 300-request script)"; fail=1; fi

# The hook is registered for the execute tool in settings.json.
cases=$((cases + 1))
if ! jq -e --arg h "/home/natkins/.claude/hooks/confirm-cloudflare-delete.sh" \
  '.hooks.PreToolUse[] | select(.hooks[].command == $h) | .matcher | test("cloudflare-api__execute")' \
  "$here/../settings.json" >/dev/null; then
  echo "FAIL: settings.json does not register confirm-cloudflare-delete.sh for the execute tool"; fail=1
fi

echo "$cases cloudflare guard cases (${ms} ms per call on a 300-request script)"
if [ $fail -eq 0 ]; then echo "all cloudflare guard tests passed"; else exit 1; fi

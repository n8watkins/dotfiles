#!/usr/bin/env bash
# Tests for confirm-cloudflare-delete.sh. Run: bash home/.claude/hooks/confirm-cloudflare-delete.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
hook="$here/confirm-cloudflare-delete.sh"
# The Python sits inside a single-quoted bash string: a stray single quote in it
# ends the string early and the hook breaks in ways cases may not show.
if sed -n "/^exec python3 -I -c /,/^'\$/p" "$hook" | sed '1d;$d' | grep -n "'"; then
  echo "FAIL: a single quote inside the hook's Python (use \\x27)"; exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

TOOL=mcp__plugin_cloudflare_cloudflare-api__execute
fail=0
cases=0
check() { # expect(ask|allow) payload [text the reason must contain] [label]
  local expect=$1 payload=$2 want=${3:-} label=${4:-} out got rc shown
  cases=$((cases + 1))
  shown=${label:-${payload:0:300}}
  out=$(printf '%s' "$payload" | "$hook" 2>"$tmp/stderr")
  rc=$?
  if [ -s "$tmp/stderr" ] || [ $rc -ne 0 ]; then
    printf 'FAIL (hook error, exit %s: %s): %s\n' "$rc" "$(cat "$tmp/stderr")" "$shown"
    fail=1
  fi
  if printf '%s' "$out" | grep -q '"permissionDecision": "ask"'; then got=ask; else got=allow; fi
  if [ "$got" != "$expect" ]; then
    printf 'FAIL (expected %s, got %s): %s\n' "$expect" "$got" "$shown"
    fail=1
  elif [ "$got" = allow ] && [ -n "$out" ]; then
    printf 'FAIL (allow must be silent, printed %s): %s\n' "$out" "$shown"
    fail=1
  elif [ -n "$want" ] && ! printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -qF -- "$want"; then
    printf 'FAIL (reason lacks "%s": %s): %s\n' "$want" "$out" "$shown"
    fail=1
  fi
}
timed() { # max-ms expect payload [reason text] [label]: check, and fail when one call is slower
  local start ms
  start=$(date +%s%N)
  check "$2" "$3" "${4:-}" "${5:-}"
  ms=$(( ($(date +%s%N) - start) / 1000000 ))
  cases=$((cases + 1))
  if [ "$ms" -ge "$1" ]; then printf 'FAIL (slow: %s ms, limit %s ms): %s\n' "$ms" "$1" "${5:-}"; fail=1; fi
  printf '  %-58s %4s ms\n' "${5:-}" "$ms"
}
payload_for() { # code -> execute payload (through a file: large code exceeds the argument limit)
  printf '%s' "$1" >"$tmp/code"
  jq -n --rawfile c "$tmp/code" --arg t "$TOOL" '{tool_name:$t,tool_input:{code:$c},permission_mode:"default",hook_event_name:"PreToolUse"}'
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
run ask 'async () => { const m = "DELETE"; return cloudflare.request({ method: m, path: "/zones/z" }); }' 'DELETE to /zones/z'
run ask 'async () => { let m = "GET"; if (x) m = "DELETE"; return cloudflare.request({ method: m, path: "/zones/z" }); }' 'method could not be read'
run ask 'async () => cloudflare.request({ method: "DEL" + "ETE", path: "/zones/z" })' 'DELETE to /zones/z'
run ask 'async () => cloudflare.request({ method: "DEL" + suffix, path: "/zones/z" })' 'method could not be read'
run ask 'async () => cloudflare.request({ method: ["DE", "LETE"].join(""), path: "/zones/z" })' 'method could not be read'
run ask 'async () => cloudflare.request({ method: dryRun ? "GET" : "DELETE", path: "/zones/z" })' 'DELETE to /zones/z'
run ask 'async () => cloudflare.request({ method: dryRun ? "GET" : verb, path: "/zones/z" })' 'method could not be read'
run allow 'async () => cloudflare.request({ method: exists ? "PUT" : "POST", path: "/zones/z/dns_records" })'
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

# Review fixes (2026-11-16). Each group failed on the first version of the hook.

# 1. Large calls: the payload is read from stdin, not passed as an argument
# (over 128 KiB the exec failed with "Argument list too long" and the call ran).
echo "large and nested inputs (one call each):"
pad200=$(head -c 200000 /dev/zero | tr '\0' x)
src12=$(for _ in $(seq 1 20000); do printf 'export default { fetch() { return new Response(\x27x\x27); } };\\n'; done)
timed 150 ask "$(payload_for "async () => { const pad = \"$pad200\"; return cloudflare.request({ method: \"DELETE\", path: \"/zones/z/dns_records/1\" }); }")" 'DELETE to /zones/z/dns_records/1' '200 KB call with a DELETE'
timed 150 allow "$(payload_for "async () => { const pad = \"$pad200\"; return cloudflare.request({ path: \"/zones\" }); }")" '' '200 KB call, GET only'
timed 150 ask "$(payload_for "async () => { const src = \"$src12\"; await cloudflare.request({ method: \"PUT\", path: \"/accounts/a/workers/scripts/w\", body: src }); return cloudflare.request({ method: \"DELETE\", path: \"/accounts/a/workers/scripts/old\" }); }")" 'DELETE to /accounts/a/workers/scripts/old' '1.2 MB Worker upload plus a DELETE'
timed 150 allow "$(payload_for "async () => cloudflare.request({ method: \"PUT\", path: \"/accounts/a/workers/scripts/w\", body: \"$src12\" })")" '' '1.2 MB Worker upload'

# 3. Nested templates are read once per level, not once per path through them.
nest() { printf 'async () => { await cloudflare.request({ method: "DELETE", path: "/zones/0/dns_records/0" }); return %s"x"%s; }' \
  "$(printf '`${%.0s' $(seq 1 "$1"))" "$(printf '}`%.0s' $(seq 1 "$1"))"; }
timed 100 ask "$(payload_for "$(nest 40)")" 'DELETE to /zones/0/dns_records/0' 'templates nested 40 deep'
timed 150 ask "$(payload_for "$(nest 3000)")" 'nested too deeply' 'templates nested 3000 deep (asks, no error)'

# 2. Fails closed: input it cannot read asks, and a failure to start exits
# non-zero so the registration (onFailure: block) stops the call.
check ask "$(printf '{"tool_name":"%s","tool_input":{"code":"\xff\xfe"}}' "$TOOL")" 'could not read'
check ask '[1, 2]' 'could not read'
check ask 'null' 'could not read'
cases=$((cases + 1))
if printf '%s' "$(payload_for 'async () => 1')" | env PATH=/nonexistent /bin/bash "$hook" >/dev/null 2>&1; then
  echo "FAIL: the hook exited 0 without python3 (onFailure: block needs a non-zero exit)"; fail=1
fi

# 4. A repeated key: JavaScript keeps the last one.
run ask 'async () => cloudflare.request({ method: "GET", method: "DELETE", path: "/zones/z" })' 'method could not be read'
run ask 'async () => cloudflare.request({ method: "GET", path: "/zones/z", method: "GET" })' 'method could not be read'

# 5. Computed keys and indirect construction: read when they can be, else the backstop asks.
run ask 'async () => cloudflare.request({ ["method"]: "DELETE", path: "/zones/z" })' 'DELETE to /zones/z'
run ask 'async () => cloudflare.request({ [`method`]: "DELETE", path: "/zones/z" })' 'DELETE to /zones/z'
run ask 'async () => cloudflare.request({ method: "DELETE", path: "/zones/z" })' 'DELETE to /zones/z'
run ask 'async () => cloudflare.request({ method: "DELETE", path: "/zones/z" })' 'DELETE to /zones/z'
run ask 'async () => cloudflare.request({ ["me" + "thod"]: verb, path: "/zones/z" })' 'computed key'
run ask 'async () => { const k = pick(); return cloudflare.request({ [k]: verb, path: "/zones/z" }); }' 'computed key'
run ask 'async () => { const o = { path: "/zones/z" }; o["meth" + "od"] = verb; return cloudflare.request(o); }' 'computed key'
run ask 'async () => cloudflare.request(Object.fromEntries(pairs))' 'fromEntries'
run ask 'async () => { const m = new Map([["method", "DELETE"]]); return cloudflare.request({ ...Object.fromEntries(m), path: "/zones/z" }); }' 'string DELETE'
run ask 'async () => { const o = { path: "/zones/z" }; Object.defineProperty(o, "me" + "thod", { value: verb }); return cloudflare.request(o); }' 'defineProperty'
run ask 'async () => { const o = { path: "/zones/z" }; Reflect.set(o, k, v); return cloudflare.request(o); }' 'Reflect'
run ask $'async () => cloudflare.request(JSON.parse(\'{"method":"DELETE","path":"/zones/z"}\'))' 'JSON text that sends DELETE'
run ask 'async () => eval(code)' 'eval'
run ask 'async () => new Function("cf", body)(cloudflare)' 'Function'
run ask 'async () => cloudflare.request({ get method() { return verb; }, path: "/zones/z" })' 'method could not be read'
run ask 'async () => { class R { method = verb; path = "/zones/z"; } return cloudflare.request({ ...new R() }); }' 'method could not be read'
# ...without false alarms on Worker source, comparisons, names and ordinary maps.
run allow 'async () => { const src = "export default { fetch(req) { if (req.method === \"DELETE\") return fetch(u, { method: \"DELETE\" }); return new Response(\"ok\"); } }"; const fd = new FormData(); fd.append("metadata", JSON.stringify({ main_module: "w.js" })); fd.append("w.js", new Blob([src]), "w.js"); return cloudflare.request({ method: "PUT", path: `/accounts/${a}/workers/scripts/api`, body: fd }); }'
run allow 'async () => cloudflare.request({ method: "PUT", path: `/accounts/${a}/workers/scripts/api`, body: `export default { fetch(req) { return fetch(u, { method: "DELETE" }); } }` })'
run allow 'async () => cloudflare.request({ method: "POST", path: `/zones/${z}/dns_records`, body: { type: "CNAME", name: "delete", content: "x.workers.dev" } })'
run allow 'async () => cloudflare.request({ method: "PUT", path: "/accounts/a/workers/scripts/delete", body: { main_module: "w.js" } })'
run allow 'async () => { const r = await cloudflare.request({ path: "/zones/z/dns_records" }); return r.result.filter((x) => x.comment !== "delete"); }'
run allow 'async () => { const out = {}; for (const z of (await cloudflare.request({ path: "/zones" })).result) out[z.id] = z.name; return out; }'
run allow 'async () => { const POST = "POST"; return cloudflare.request({ method: POST, path: `/zones/${z}/dns_records`, body: {} }); }'
run allow 'async () => { switch (kind) { case "delete": return 1; default: return cloudflare.request({ path: "/zones" }); } }'

# 6. Paths built by concatenation or templates still meet the table.
run ask 'async () => cloudflare.request({ method: "POST", path: "/zones/" + zoneId + "/purge_cache", body: { purge_everything: true } })' 'whole cache'
run ask 'async () => cloudflare.request({ method: "POST", path: "/user/" + "tokens", body: { name: "x" } })' 'API token (/user/tokens)'
run ask 'async () => { const base = `/accounts/${a}`; return cloudflare.request({ method: "POST", path: base + "/storage/kv/namespaces/" + ns + "/bulk/delete", body: keys }); }' 'KV keys in bulk'
run ask 'async () => { const p = "/accounts/a/r2/buckets/b/" + "lifecycle"; return cloudflare.request({ method: "PUT", path: p, body: {} }); }' 'lifecycle'

# 7. New table rows, each with a near miss that stays silent.
run ask 'async () => cloudflare.request({ method: "POST", path: `/zones/${z}/dns_records/batch`, body: { deletes: [{ id: "r1" }] } })' 'deletes DNS records'
run allow 'async () => cloudflare.request({ method: "POST", path: `/zones/${z}/dns_records/batch`, body: { posts: [{ type: "A", name: "x", content: "1.2.3.4" }] } })'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/vectorize/v2/indexes/idx/delete_by_ids`, body: { ids: ["1"] } })' 'Vectorize'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/queues/${q}/purge`, body: { delete_messages_permanently: true } })' 'queue'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/d1/database/${db}/time_travel/restore`, query: { bookmark: "b" } })' 'restores a D1 database'
run allow 'async () => cloudflare.request({ path: `/accounts/${a}/d1/database/${db}/time_travel/bookmark` })'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/d1/database/${db}/import`, body: { action: "init" } })' 'imports SQL'
run ask 'async () => cloudflare.request({ method: "POST", path: `/zones/${z}/email/routing/disable` })' 'Email Routing'
run allow 'async () => cloudflare.request({ method: "POST", path: `/zones/${z}/email/routing/enable` })'
run ask 'async () => cloudflare.request({ method: "PATCH", path: `/zones/${z}`, body: { paused: true } })' 'pauses'
run allow 'async () => cloudflare.request({ method: "PATCH", path: `/zones/${z}`, body: { paused: false } })'
run allow 'async () => cloudflare.request({ method: "PATCH", path: `/zones/${z}`, body: { plan: { id: "free" } } })'
run ask 'async () => cloudflare.request({ method: "PUT", path: `/zones/${z}/rulesets/phases/http_request_firewall_custom/entrypoint`, body: { rules: [] } })' 'ruleset phase'
run allow 'async () => cloudflare.request({ method: "POST", path: `/zones/${z}/rulesets/${id}/rules`, body: { action: "block" } })'
run ask 'async () => cloudflare.request({ method: "PUT", path: `/accounts/${a}/rules/lists/${l}/items`, body: [] })' 'every item in a list'
run allow 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/rules/lists/${l}/items`, body: [{ ip: "1.2.3.4" }] })'
run ask 'async () => cloudflare.request({ method: "PUT", path: `/accounts/${a}/access/apps/${app}`, body: { name: "x", policies: [] } })' 'Access application'
run allow 'async () => cloudflare.request({ method: "PUT", path: `/accounts/${a}/access/apps/${app}`, body: { name: "x", session_duration: "24h" } })'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/challenges/widgets/${s}/rotate_secret`, body: { invalidate_immediately: true } })' 'Turnstile'
run ask 'async () => cloudflare.request({ method: "PUT", path: `/accounts/${a}/workers/dispatch/namespaces/ns/scripts/rooms`, body: { metadata: { migrations: { deleted_classes: ["Room"] } } } })' 'Durable Object'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/registrar/domains/n8builds.dev/transfer`, body: {} })' 'Registrar'
run allow 'async () => cloudflare.request({ path: `/accounts/${a}/registrar/domains` })'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/email/sending/send`, body: { to: "x@example.com", from: "a@n8builds.dev", subject: "hi", text: "hi" } })' 'sends an email'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/email/sending/send_raw`, body: { mime_message: raw } })' 'sends an email'
run allow 'async () => cloudflare.request({ path: `/accounts/${a}/email/sending/suppressions` })'

# 8. D1 looks at the SQL sent, the tokens row at request paths, and purge at the body.
run allow 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/d1/database/${db}/query`, body: { sql: "INSERT INTO tickets (body) VALUES (?)", params: ["Please delete my account"] } })'
run allow 'async () => { const r = await cloudflare.request({ method: "POST", path: `/accounts/${a}/d1/database/${db}/query`, body: { sql: "SELECT * FROM users" } }); for (const row of r.result[0].results) delete row.password; return r; }'
run ask 'async () => { const sql = "DEL" + "ETE FROM " + t; return cloudflare.request({ method: "POST", path: `/accounts/${a}/d1/database/${db}/query`, body: { sql } }); }' 'D1'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/d1/database/${db}/query`, body: { sql: "UPDATE users SET email = NULL" } })' 'D1'
run allow 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/d1/database/${db}/query`, body: { sql: "UPDATE users SET email = ? WHERE id = ?", params: [e, id] } })'
run ask 'async () => cloudflare.request({ method: "POST", path: `/accounts/${a}/d1/database/${db}/query`, body: { sql: query } })' 'could not read'
run allow 'async () => { const v = "/user/tokens/verify"; await cloudflare.request({ path: v }); return cloudflare.request({ method: "POST", path: `/zones/${z}/dns_records`, body: { type: "A", name: "x", content: "1.2.3.4" } }); }'
run allow 'async () => { const note = "never use purge_everything"; return cloudflare.request({ method: "POST", path: `/zones/${z}/purge_cache`, body: { prefixes: ["n8builds.dev/a"] } }); }'
run allow 'async () => { /* not purge_everything */ return cloudflare.request({ method: "POST", path: `/zones/${z}/purge_cache`, body: { tags: ["a"] } }); }'

# The reviewer's bypass and false-alarm inputs (2026-11-16), kept as permanent
# cases in confirm-cloudflare-delete.cases.jsonl (one JSON object per line:
# id, expect, label, code). attack-* expect ask when the code deletes at run
# time; attack2-* hold the destructive table and false-alarm cases.
# attack2-T13 (add an account member) and attack2-T24 (overwrite a Secrets
# Store secret) are not on the owner's list and stay silent. The 200 KB and
# 140 KB inputs (attack-H9, H10) are the large-call cases above.
jsonl_cases=0
while IFS= read -r line; do
  jsonl_cases=$((jsonl_cases + 1))
  check "$(jq -r .expect <<<"$line")" "$(jq -c --arg t "$TOOL" '{tool_name:$t,tool_input:{code:.code}}' <<<"$line")" '' \
    "$(jq -r '.id + " " + .label' <<<"$line")"
done <"$here/confirm-cloudflare-delete.cases.jsonl"
cases=$((cases + 1))
if [ "$jsonl_cases" -lt 117 ]; then echo "FAIL: only $jsonl_cases reviewer cases read"; fail=1; fi

# Speed: well under 100 ms per call on a large script (python start included).
big=$(for i in $(seq 1 300); do printf 'await cloudflare.request({ method: "GET", path: `/zones/%s/dns_records`, query: { page: %s } });\n' "$i" "$i"; done)
payload=$(jq -n --arg c "async () => { $big }" --arg t "$TOOL" '{tool_name:$t,tool_input:{code:$c}}')
start=$(date +%s%N)
for _ in 1 2 3 4 5; do printf '%s' "$payload" | "$hook" >/dev/null; done
ms=$(( ($(date +%s%N) - start) / 5000000 ))
cases=$((cases + 1))
if [ "$ms" -ge 100 ]; then echo "FAIL (slow: ${ms} ms per call on a 300-request script)"; fail=1; fi

# The hook is registered for the execute tool in settings.json, with a short
# timeout and onFailure: block, so a failure or a stall stops the call.
cases=$((cases + 1))
if ! jq -e --arg h "/home/natkins/.claude/hooks/confirm-cloudflare-delete.sh" \
  '[.hooks.PreToolUse[] | select(.matcher | test("cloudflare-api__execute")) | .hooks[]
    | select(.command == $h and .timeout == 10 and .onFailure == "block")] | length == 1' \
  "$here/../settings.json" >/dev/null; then
  echo "FAIL: settings.json does not register confirm-cloudflare-delete.sh for the execute tool with timeout 10 and onFailure block"; fail=1
fi

echo "$cases cloudflare guard cases (${ms} ms per call on a 300-request script)"
if [ $fail -eq 0 ]; then echo "all cloudflare guard tests passed"; else exit 1; fi

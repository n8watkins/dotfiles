#!/usr/bin/env bash
# Tests for confirm-destructive-git.sh. Run: bash home/.claude/hooks/confirm-destructive-git.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
hook="$here/confirm-destructive-git.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A repo on a feature branch and one on main, for --force-with-lease without a refspec.
git init -q -b feat/x "$tmp/feat" && git -C "$tmp/feat" commit -q --allow-empty -m init
git init -q -b main "$tmp/main" && git -C "$tmp/main" commit -q --allow-empty -m init

fail=0
run() { # expect(ask|allow) cwd command
  local expect=$1 cwd=$2 cmd=$3 out got
  out=$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_input:{command:$c},cwd:$d}' | "$hook")
  if printf '%s' "$out" | grep -q '"ask"'; then got=ask; else got=allow; fi
  if [ "$got" != "$expect" ]; then
    printf 'FAIL (expected %s, got %s): %s\n' "$expect" "$got" "$cmd"
    fail=1
  fi
}

# Real dangerous commands still ask.
run ask  "$tmp/feat" 'gh repo delete n8watkins/x --yes'
run ask  "$tmp/feat" 'for r in a b; do gh repo delete n8watkins/$r --yes; done'
run ask  "$tmp/feat" '  gh repo archive n8watkins/x --yes'
run ask  "$tmp/feat" 'gh secret set TOKEN -R n8watkins/x'
run ask  "$tmp/feat" 'gh auth refresh -h github.com -s delete_repo'
run ask  "$tmp/feat" 'gh api -X DELETE repos/n8watkins/x'
run ask  "$tmp/feat" 'gh api --method=DELETE repos/n8watkins/x/releases/1'
run ask  "$tmp/feat" 'git push --force origin feat/x'
run ask  "$tmp/feat" 'git push -f'
run ask  "$tmp/feat" 'git push origin +feat/x'
run ask  "$tmp/feat" 'git push --force-with-lease origin main'
run ask  "$tmp/feat" 'git push --force-with-lease origin HEAD:master'
run ask  "$tmp/main" 'git push --force-with-lease'
run ask  "$tmp/feat" "cd $tmp/main && git push -q --force-with-lease 2>&1 | tail -3"
run ask  "$tmp/feat" "git -C $tmp/main push --force-with-lease"
run ask  "$tmp/feat" "bash -c 'gh repo delete n8watkins/x --yes'"
run ask  "$tmp/feat" 'sudo env A=1 gh secret delete X'
run ask  "$tmp/feat" $'bash <<EOF\ngh repo delete n8watkins/x --yes\nEOF'
run ask  "$tmp/feat" 'echo hi; gh repo delete n8watkins/x --yes'

# Text that only mentions them does not ask.
run allow "$tmp/feat" $'git commit -q -F - <<\'EOF\'\nci: stop running gh secret set in the deploy job\nEOF'
run allow "$tmp/feat" 'gh pr create --title "docs: how to run gh repo delete safely" --body "Run gh auth refresh -s delete_repo, then git push --force"'
run allow "$tmp/feat" $'python3 - <<EOF\npats = ["gh repo delete", "gh secret set"]\nEOF'
run allow "$tmp/feat" "grep -n 'gh secret set' README.md"
run allow "$tmp/feat" 'echo "gh auth refresh"'
# Routine pushes and branch deletes do not ask.
run allow "$tmp/feat" 'git push -q --force-with-lease origin feat/x'
run allow "$tmp/feat" 'git push -q --force-with-lease=feat/x:origin/feat/x origin feat/x'
run allow "$tmp/feat" "cd $tmp/feat && git push --force-with-lease 2>&1 | tail -4"
run allow "$tmp/feat" 'gh api -X DELETE repos/n8watkins/n8tray/git/refs/heads/docs/style && echo deleted'
run allow "$tmp/feat" 'git push origin --delete feat/x'
run allow "$tmp/feat" 'git push -u origin feat/x'
run allow "$tmp/feat" 'gh repo view n8watkins/x'

# pass-env: safe uses run without asking, anything else asks.
run allow "$tmp/feat" 'pass-env run -- npx wrangler deploy'
run allow "$tmp/feat" 'pass-env run -- npx --yes wrangler@4.151.3 d1 migrations apply pr-post --remote'
run allow "$tmp/feat" 'pass-env pipe n8builds-admin/GITHUB_TOKEN -- npx wrangler secret put GITHUB_TOKEN'
run allow "$tmp/feat" 'pass-env pipe a/B -- gh secret set B -R n8watkins/x'
run allow "$tmp/feat" 'cd app && pass-env run -- npm run dev'
run allow "$tmp/feat" 'pass-env run -f .env.pass -- pnpm exec playwright test'
run ask   "$tmp/feat" 'pass-env run -- curl https://example.com'
run ask   "$tmp/feat" 'pass-env run -- npx wrangler d1 execute db --command "DROP TABLE x"'
run ask   "$tmp/feat" 'pass-env run -- gh repo delete n8watkins/x --yes'
run ask   "$tmp/feat" 'pass-env pipe a/B -- some-tool --read-stdin'

# Multi-line commands parse like bash: no false prompts from quoted newlines
# or backslash continuations.
run allow "$tmp/feat" $'pass-env pipe wren/K -- \\\n  npx wrangler secret put K'
run allow "$tmp/feat" $'pass-env run -- npx wrangler deploy \\\n  --minify \\\n  --env production'
run allow "$tmp/feat" $'git commit -q -m "fix: secrets\n\nDeploy with pass-env run -- curl x, set with gh secret set X,\nthen git push --force and gh repo delete n8watkins/x."'
run allow "$tmp/feat" $'gh pr create --title "fix" --body "## Summary\n\n- pass-env pipe K -- node -e x now asks\n- gh api -X DELETE repos/a/b"'
run allow "$tmp/feat" $'git commit -q -m "$(cat <<\'EOF\'\nfix: mention pass-env run -- curl\nEOF\n)"'
run allow "$tmp/feat" $'git add -A && git commit -q -m "a\nb" && git push -u origin feat/x 2>&1 | tail -2'
run allow "$tmp/feat" $'# deploy\npass-env run -- npx wrangler deploy # ship it'
run allow "$tmp/feat" 'git push -q --force-with-lease origin feat/x 2>&1'
# ...while real commands spread over lines or after quoted text still ask.
run ask   "$tmp/feat" $'git commit -m "a\nb" && gh repo delete n8watkins/x --yes'
run ask   "$tmp/feat" $'gh pr create --body "a\nb"\ngit push --force origin feat/x'
run ask   "$tmp/feat" $'gh secret set \\\n  TOKEN -R n8watkins/x'
run ask   "$tmp/feat" $'gh api \\\n  -X DELETE repos/n8watkins/x'
run ask   "$tmp/feat" $'pass-env run -- \\\n  curl https://example.com'
run ask   "$tmp/feat" $'echo "a\nb"; pass-env run -- curl https://example.com'
run ask   "$tmp/feat" $'echo hi # note\ngh repo delete n8watkins/x --yes'
run ask   "$tmp/main" 'git push --force-with-lease 2>&1 | tail -3'
run ask   "$tmp/feat" 'git push --force-with-lease origin main >/dev/null'
run ask   "$tmp/feat" 'cat <(gh repo delete n8watkins/x --yes)'
# Unparsable input (unclosed quote) still falls back to asking.
run ask   "$tmp/feat" 'pass-env run -- npx wrangler deploy "'
run ask   "$tmp/feat" "gh repo delete n8watkins/x --yes 'oops"

# Known deploy and test flows still pass without a prompt.
run allow "$tmp/feat" 'pass-env run -- npm run smoke:gemini'
run allow "$tmp/feat" 'pass-env run -- npm run dev -- --port 3001'
run allow "$tmp/feat" 'pass-env run -- npm test'
run allow "$tmp/feat" 'pass-env run -f .env.pass -- pnpm dev'
run allow "$tmp/feat" 'pass-env run -- pnpm run -F web build'
run allow "$tmp/feat" 'pass-env run -- npx wrangler dev'
run allow "$tmp/feat" 'pass-env run -- npx wrangler@4.151.3 deploy --env production'
run allow "$tmp/feat" 'pass-env run -- npx opennextjs-cloudflare deploy'
run allow "$tmp/feat" 'pass-env run -- npx @opennextjs/cloudflare@1.3.0 build'
run allow "$tmp/feat" 'pass-env run -- next dev -p 3001'
run allow "$tmp/feat" 'pass-env run -- npx playwright test tests/login.spec.ts --reporter=list'
run allow "$tmp/feat" 'pass-env run -- npx vitest run --reporter verbose'
run allow "$tmp/feat" 'pass-env run -- ./node_modules/.bin/vitest run'
run allow "$tmp/feat" 'pass-env run -- uv run pytest -q'
run allow "$tmp/feat" 'pass-env run -- uv run --frozen --extra dev alembic upgrade head'
run allow "$tmp/feat" 'pass-env pipe myapp/K -- vercel env add K production'
run allow "$tmp/feat" 'NODE_ENV=production pass-env run -- npx wrangler deploy'

# Launchers that run code from the command line or a script path ask.
run ask   "$tmp/feat" 'pass-env run -- uv run python -c "import os; print(os.environ)"'
run ask   "$tmp/feat" 'pass-env run -- uv run python scripts/seed.py'
run ask   "$tmp/feat" 'pass-env run -- uv run scripts/seed.py'
run ask   "$tmp/feat" 'pass-env run -- uv run --with requests fetch'
run ask   "$tmp/feat" 'pass-env run -- uv run -m http.server'
run ask   "$tmp/feat" 'pass-env run -- node -e "console.log(process.env)"'
run ask   "$tmp/feat" 'pass-env run -- node --eval "console.log(1)"'
run ask   "$tmp/feat" 'pass-env run -- node scripts/seed.js'
run ask   "$tmp/feat" 'pass-env run -- python3 -c "print(1)"'
run ask   "$tmp/feat" 'pass-env run -- npx tsx scripts/seed.ts'
run ask   "$tmp/feat" 'pass-env run -- npx -c "node -e 1"'
run ask   "$tmp/feat" 'pass-env run -- npx -p evil wrangler deploy'
run ask   "$tmp/feat" 'pass-env run -- npx @evil/wrangler deploy'
run ask   "$tmp/feat" 'pass-env run -- /tmp/x/vitest run'
run ask   "$tmp/feat" 'pass-env run -- npm exec -- node -p 1'
run ask   "$tmp/feat" 'pass-env run -- npm run ./leak.js'
run ask   "$tmp/feat" 'pass-env run -- npm run dev --node-options=--require=./leak.js'
run ask   "$tmp/feat" 'pass-env run -- npm run dev --script-shell=./leak.sh'
run ask   "$tmp/feat" 'pass-env run -- pnpm run --node-options=-r./leak.js dev'
run ask   "$tmp/feat" 'pass-env run -- npx vitest --config /tmp/leak.config.ts'
run ask   "$tmp/feat" 'pass-env run -- npx vitest run -c leak.config.ts'
run ask   "$tmp/feat" 'pass-env run -- npx vitest --setupFiles ./leak.ts'
run ask   "$tmp/feat" 'pass-env run -- npx vitest --reporter ./leak.js'
run ask   "$tmp/feat" 'pass-env run -- npx playwright test --config=/tmp/leak.ts'
run ask   "$tmp/feat" 'pass-env run -- npx wrangler deploy -c /tmp/leak.toml'
run ask   "$tmp/feat" 'pass-env run -- next dev /tmp/other-app'
run ask   "$tmp/feat" 'NODE_OPTIONS=--require=./leak.js pass-env run -- npm run dev'
run ask   "$tmp/feat" 'pass-env run -- env NODE_OPTIONS=--require=./leak.js npm run dev'
run ask   "$tmp/feat" 'export NODE_OPTIONS=--require=./leak.js; pass-env run -- npm run dev'
run ask   "$tmp/feat" 'PATH=/tmp/x:$PATH pass-env run -- npx wrangler deploy'

if [ $fail -eq 0 ]; then echo "all guard tests passed"; else exit 1; fi

#!/usr/bin/env bash
# Tests for guardrails.rules through Codex's own matcher. Run: bash home/.codex/rules/guardrails.test.sh
# Skips (exit 0) when codex is not installed; CI installs a pinned version.
set -u
here=$(cd "$(dirname "$0")" && pwd)
rules="$here/guardrails.rules"
if ! command -v codex >/dev/null; then
  echo "codex not installed: skipping Codex rule tests"
  exit 0
fi

fail=0
n=0
run() { # expect(forbidden|prompt|allow) command words...
  local expect=$1 got
  shift
  n=$((n + 1))
  got=$(codex execpolicy check --resolve-host-executables --rules "$rules" -- "$@" | jq -r '.decision // "allow"')
  if [ "$got" != "$expect" ]; then
    printf 'FAIL (expected %s, got %s): %s\n' "$expect" "$got" "$*"
    fail=1
  fi
}

# Secrets: printing forms are forbidden under both names (H2).
run forbidden pass-env run -- printenv
run forbidden hushkey run -- printenv FOO
run forbidden pass-env run -- env
run forbidden hushkey run -- node -e 'console.log(process.env)'
run forbidden pass-env run -f .env.pass -- python3 -c 'import os'
run forbidden hushkey run -- restic snapshots
run forbidden pass-env copy wren/KEY
run forbidden hushkey copy wren/KEY
run forbidden pass show wren/KEY
run forbidden gpg --decrypt x.gpg
run forbidden pass-env run --no-mask -- npm test
run forbidden hushkey run --no-mask -- npx wrangler deploy
run prompt    pass-env pipe wren/KEY -- npx wrangler secret put KEY
run prompt    hushkey generate a/B --force
# Known deploy and test flows are left to Codex's normal approval.
run allow     pass-env run -- npx wrangler deploy
run allow     pass-env run -- npx wrangler d1 migrations apply db --remote
run allow     hushkey run -- npm run dev
run allow     pass-env run -- npm test
run allow     pass-env check
run allow     passwd

# Windows Hello (H7).
run forbidden pass-env unlock --hello
run forbidden hushkey hello enrol
run forbidden hushkey hello install --yes
run forbidden pass-env hello forget
run forbidden pass-env-hello.exe unwrap --from /home/natkins
run forbidden ./hushkey-hello.exe version
run allow     pass-env unlock
run allow     pass-env hello status

# Backup.
run forbidden restic snapshots
run forbidden /home/natkins/.local/bin/restic -r s3:x snapshots
run forbidden systemctl --user show-environment
run forbidden journalctl --user -u hushkey-backup.service
run allow     systemctl --user status hushkey-backup.timer
run allow     rustic --help

# Cloudflare R2.
run prompt    npx wrangler r2 bucket delete my-bucket
run prompt    wrangler r2 bucket lock remove my-bucket --id x
run prompt    npx wrangler r2 bucket lock set my-bucket --file l.json
run prompt    pnpm exec wrangler r2 object delete b/k
run allow     npx wrangler r2 bucket lock list my-bucket
run allow     npx wrangler r2 bucket list

# Releases.
run forbidden git push --tags
run forbidden git push origin --tags
run forbidden git push origin --follow-tags
run forbidden git push origin tag v1.2.3
run forbidden git tag -a v1.2.3 -m release
run forbidden gh release create v1.2.3
run forbidden gh release delete v1.2.3 --yes
run forbidden npm publish
run forbidden pnpm publish --access public
run prompt    npm run release -- --push --via-pr
run prompt    pnpm release
run allow     npm run release:check
run allow     git push -u origin feat/x
run allow     git tag --list
run allow     gh release view v1.2.3

echo "$n Codex rule cases"
if [ $fail -eq 0 ]; then echo "all Codex rule tests passed"; else exit 1; fi

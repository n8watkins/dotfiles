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
run ask  "$tmp/feat" 'pass-env pipe a/B -- gh secret set B -R n8watkins/x'
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

if [ $fail -eq 0 ]; then echo "all guard tests passed"; else exit 1; fi

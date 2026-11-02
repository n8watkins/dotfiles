---
name: github-access
description: Use before deleting a GitHub repository, changing what the local gh login is allowed to do, or touching repo secrets. Covers the temporary delete-permission cycle and the confirmation prompts.
---

# GitHub access

The local `gh` login has no `delete_repo` permission on purpose (scopes: gist, read:org, repo, workflow).
Destructive commands also trigger a Claude Code confirmation prompt (`~/.claude/hooks/confirm-destructive-git.sh` and `permissions.ask` in `~/.claude/settings.json`).

## Deleting a repository

1. Confirm the exact repository with the owner, and check it is not still useful (backed up, archived elsewhere, or empty).
2. Run `gh auth refresh -h github.com -s delete_repo` in the background, read the one-time code from its output, and give the owner the code and https://github.com/login/device to approve.
3. Run `gh repo delete <owner>/<repo> --yes`; the owner approves the confirmation prompt.
4. Immediately run `gh auth refresh -h github.com --remove-scopes delete_repo` the same way (another browser code).
5. Verify with `gh api -i user | grep -i x-oauth-scopes` that `delete_repo` is gone.

## Rules

- Never add `delete_repo` permanently.
- Tell the owner to answer confirmation prompts with option 1 (allow once) or 3 (no), never "don't ask again", which adds an allow rule that removes the guard.
- Never print or commit token values; pipe secrets from `pass` (`pass show … | gh secret set NAME`).

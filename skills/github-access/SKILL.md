---
name: github-access
description: Use before deleting a GitHub repository, changing what the local gh login is allowed to do, or touching repo secrets. Covers the temporary delete-permission cycle and the confirmation prompts.
---

# GitHub access

The local `gh` login has no `delete_repo` permission on purpose (scopes: gist, read:org, repo, workflow).
The shared command guard is `~/.claude/hooks/confirm-destructive-git.sh`.
Claude Code uses its confirmation response alongside `permissions.ask` in `~/.claude/settings.json`.
Codex uses `~/.config/agent-hooks/codex-pre-tool-use.py` to translate that response into a denial, because its PreToolUse hook does not support an interactive ask decision.
The Codex hook must first be trusted through `/hooks`.
When Codex denies the call, report the exact command and reason and stop; the owner's approval in chat alone does not change the hook's decision.
The owner can perform the approved operation in their terminal, then the agent verifies the result with a read-only command.

## Deleting a repository

1. Confirm the exact repository with the owner, and check it is not still useful (backed up, archived elsewhere, or empty).
2. Run `gh auth refresh -h github.com -s delete_repo` in the background, read the one-time code from its output, and give the owner the code and https://github.com/login/device to approve.
3. Run `gh repo delete <owner>/<repo> --yes` only through the approved path for the current harness.
   In Claude Code, the owner answers the confirmation prompt.
   In Codex, if the guard denies it, stop and have the owner perform the approved command; do not retry through another tool or wrapper.
4. Immediately run `gh auth refresh -h github.com --remove-scopes delete_repo` the same way (another browser code).
5. Verify with `gh api -i user | grep -i x-oauth-scopes` that `delete_repo` is gone.

## Rules

- Never add `delete_repo` permanently.
- Tell the owner to answer confirmation prompts with option 1 (allow once) or 3 (no), never "don't ask again", which adds an allow rule that removes the guard.
- On Codex 0.163.0, a shell hook can receive the session directory rather than an individual command's working directory.
  Use explicit `git -C <repo>` for directory-sensitive Git operations so the guard checks the intended repository.
- Never print or commit token values; pipe secrets from the store (`pass-env pipe <entry> -- gh secret set NAME`).

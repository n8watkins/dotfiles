#!/usr/bin/env bash
# User-level PreToolUse guard (every project): commands that delete or overwrite
# things on GitHub, or rewrite pushed history, always need the owner's OK.
# Emits an "ask" decision as JSON; silence = no opinion (normal rules apply).
# Covers: gh repo delete/archive, gh api DELETE calls, gh secret set/delete,
# gh auth refresh (changes the login's permissions), and force pushes. Deleting a
# remote branch (cleanup after a merge) no longer asks (owner, 2026-11-02).
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

reason=""
case "$cmd" in
  *"gh repo delete"*) reason="deletes a GitHub repository" ;;
  *"gh repo archive"*) reason="archives a GitHub repository" ;;
  *"gh secret set"*|*"gh secret delete"*|*"gh secret remove"*) reason="changes a GitHub Actions secret" ;;
  *"gh auth refresh"*) reason="changes what the GitHub login is allowed to do" ;;
esac

if [ -z "$reason" ] && printf '%s' "$cmd" | grep -qE 'gh[[:space:]]+api\b.*(-X[[:space:]]*DELETE|--method[[:space:]=]+DELETE)'; then
  reason="sends a DELETE request to the GitHub API"
fi
if [ -z "$reason" ] && printf '%s' "$cmd" | grep -qE 'git[[:space:]]+push\b.*([[:space:]](-f|--force|--force-with-lease(=[^[:space:]]*)?)([[:space:]]|$)|[[:space:]]\+[^[:space:]]+)'; then
  reason="force-pushes to a remote branch"
fi

if [ -n "$reason" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"This command %s. Confirm before it runs."}}' "$reason"
fi
exit 0

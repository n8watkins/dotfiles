---
name: merge-and-cleanup
description: Use when squash-merging a pull request, especially in a release-kit repo or when several parallel PRs are landing, and for the cleanup after every merge (worktrees, branches, servers).
---

# Merging and cleaning up

## Before merging

- Squash merges keep only the PR title as the commit header and the body you pass, so:
  - make the PR title carry the highest type (`feat` if any inner commit is a feature);
  - merge with an explicit subject and body: `gh pr merge N --squash --subject "<title> (#N)" --body "<user-facing summary>"`, never leaving inner `Release-note:` trailers in.
- When several PRs land in a row, a PR whose green CI ran on an older main can still break main. After another PR merges, update the branch (`gh pr update-branch N`) and wait for green before merging, unless it is stacked on exactly what main now is.
- Stacked PRs: before deleting a merged PR's branch, run `gh pr edit <stacked> --base main` on every PR based on it, or deleting the base closes them for good.

## After every merge

1. Remove the PR's worktree (`git worktree remove <path>`) and delete the local branch; make sure the remote branch is deleted (`--delete-branch`).
2. Stop dev servers and test servers you started, including orphans whose working directory is a deleted worktree.
3. While parallel lanes run, watch memory (`free -h`) and stay inside the machine's limits.
4. Mention in the summary what was removed.

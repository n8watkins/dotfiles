---
name: merge-and-cleanup
description: Use when squash-merging a pull request, especially in a release-kit repo or when several parallel PRs are landing, for the cleanup after every merge (worktrees, branches, servers), and whenever a lane that made a worktree ends, merged or not.
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
   Stop any browser you started for testing: `npx -y chrome-devtools-axi stop` (its bridge and headless Chrome otherwise stay alive for days; twelve left over held about 4 GB on 2026-11-11).
3. While parallel lanes run, watch memory (`free -h`) and stay inside the machine's limits.
4. Mention in the summary what was removed.

## When a lane ends without a merge

A worktree is a full copy of the repo plus its own `node_modules` and build caches (`.next` alone can reach several GB), so forgotten ones add up fast: seven Tech for Pros worktrees came to about 45 GB in November 2026.

- Before you report a lane as done, make sure its work is on GitHub (committed and pushed, or in a PR), then remove its worktree, even when the PR stays open for the owner's review or was closed. Reviewing or reopening only needs the branch on GitHub; a fresh worktree can be made later.
- Delete the local branch once its tip is on GitHub (`git branch -r --contains <sha>` shows a remote branch, or the PR merged).
- Keep a worktree only when it holds uncommitted or unpushed work, and say so in the report with its path.
- Stop the dev servers and the test browser (`npx -y chrome-devtools-axi stop`) the lane started.
- Remove a worktree's folder with `trash <path>` and then `git worktree prune`, so a mistake can still be restored for 14 days.
- Build output (`.next`, `.open-next`, `.turbo`) in a checkout you keep is cache: trash it when a lane is done with it. Keep `node_modules` and `.wrangler` (local dev databases).

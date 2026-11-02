---
name: retire-repo
description: Use when a project is being retired, archived, moved to backlog or deleted. Backs it up as a git bundle, chooses archive versus delete, and leaves a note where it went.
---

# Retiring a repository

1. Confirm with the owner what happens to it: archive on GitHub (read-only, reversible), move into a shared archive repo (for small related experiments), or delete.
2. Check nothing is lost: uncommitted files, unpushed branches (`git cherry` against the default branch to spot squash-merged ones), stashes, and untracked files worth keeping.
3. Back it up: `git bundle create <name>.bundle --all`, attach it to a release in the archive repo, then test-restore it (download, `git clone`, compare commit counts).
4. Archive (`gh repo archive`, confirmation prompt) or delete (follow the github-access playbook).
5. Leave a pointer: a README note in the archive or a line in the project list saying where it went and why.
6. Remove the local clone only after the backup is verified.

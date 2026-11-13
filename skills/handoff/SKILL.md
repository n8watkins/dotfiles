---
name: handoff
description: Create or update a zero-context project handoff for another coding-agent session. Use when the user asks to hand off, preserve session state, prepare for a context reset or compaction, or produce a continuation prompt across Codex and Claude.
---

# Handoff

Create a factual, reset-safe handoff without taking ownership of unrelated work.
The handoff is files: a status document, a kickoff file, and a one-line prompt that names the kickoff file.
Never paste the kickoff itself into chat.

## Establish Scope

1. Read the repository instructions and capture `git status --short`, the current branch, recent commits, and remotes before changing anything.
2. Separate this session's work from pre-existing or user-owned changes.
3. Never stage, commit, revert, or rewrite unrelated changes.
4. Never infer permission to push from prior pushes.
   Push only when the user explicitly authorized it for the current work.

## Select The Document

1. Follow a handoff path named by repository instructions or the user.
2. Otherwise, search tracked files for handoff documents and inspect likely candidates before selecting the one whose scope matches the current project or workstream.
3. Do not replace an established scoped handoff with a generic `docs/HANDOFF.md`.
4. If multiple candidates are plausible and none is clearly canonical, report the ambiguity and ask before overwriting one.
5. When no handoff exists, use the owner's handoff home: `~/projects/ops/handoffs/<project>/` with `STATUS.md` and `KICKOFF.md`.
   Use a repository's own `docs/HANDOFF.md` only when its instructions say so.
   Private state (open decisions, security settings, costs) never goes in a public repository.

Never edit generated files, generated sections or changelogs merely to make the handoff appear current.
Link to authoritative project documents instead.

## Record Evidence

Write for an agent with no conversation history.
Distinguish verified facts, inferences, and unknown external state.
Include:

- Project purpose, relevant architecture, and operating environment.
- Work completed, with commit hashes and intentionally uncommitted files.
- Verification commands and exact outcomes, including failures or skipped checks.
- Runtime and deployment state observed directly, with timestamps or identifiers when relevant.
- External dependencies, credentials, services, approvals, and reachability that were verified or remain blocked.
- Ordered next steps with acceptance criteria and file pointers.
- Decisions already made, constraints, risks, and commands that are known to work.
- A focused file map.

Keep the status document current while the work runs: add a dated "Update" section when a lane merges or a decision changes, so a handoff only has to add the in-flight inventory.
Do not repeat the global rules file; every session loads it.
Do not include secrets, tokens, credential commands that reveal secrets, or sensitive terminal output.
Keep each full Markdown sentence on its own physical line unless repository instructions require another format.

## Inventory What Is In Flight

Before writing, list each of these with its exact location and state, and say "none" when there is none:

- Subagents and background jobs still running: what each does, its branch and worktree, and when it last reported.
  A new session cannot message them; a compacted session can.
- Worktrees: branch, uncommitted files, unpushed commits (`git -C <path> status --short`, `git -C <path> log @{u}..`).
  Commit and push anything that would otherwise be lost, if repository rules allow, before handing off.
- Files that exist only in a session scratchpad or `/tmp`: move anything worth keeping into a repository branch, or publish it.
- Local servers listening: port, command, worktree, and whether the owner allows stopping them.
- Published pages (Artifacts) with their links, and where their sources live.
- Owner decisions: what was decided, what waits on the owner, and which standing authorities (merge, deploy, spend) the next session must confirm again.

## Compact Or Start Fresh

Tell the owner which one fits, in one line each:

- Compact when this session's agents are still running and must report back here.
- Start fresh when nothing is running, or the context is too cluttered to trust; the next session works only from the files.

Write the files first in both cases: a compaction summary is not a handoff.

## Preserve Durable Agent State

If the environment provides a sanctioned way to checkpoint durable agent state (for example an orchestrator's checkpoint tool), store a concise resume point there: active agent sessions, branches or PRs, pending decisions, blockers, and the next ordered action.
Do not invent identifiers or claim a checkpoint succeeded when the tool was unavailable or refused it.
Never retrieve or pass service credentials in a prompt, command argument, environment dump, handoff document, or checkpoint.
When no such tool exists, skip this step silently; the handoff documents are the resume point.

## Write The Kickoff File

Write `KICKOFF.md` beside the status document, for a session with no memory of this one:

1. What to read first, in order.
2. What to verify before acting (open pull requests, each worktree, listening servers, live addresses, whether earlier agents are still attached).
3. The work in order, each item with a "done when".
4. Only the project rules that are not already in the global rules file.

## Commit And Report

Follow repository commit requirements, but stage the selected handoff paths explicitly.
Keep handoff-only documentation changes in a dedicated commit when repository policy permits.
Do not commit merely because this skill was invoked if the user requested only an in-chat handoff.

End with:

1. A concise summary for the user.
2. The handoff paths and commit, if any.
3. Verification, runtime, and push status.
4. Whether to compact or start fresh, and why.
5. A one-line prompt for the owner to paste, naming only the kickoff file, for example `Read ~/projects/ops/handoffs/<project>/KICKOFF.md and follow it.`

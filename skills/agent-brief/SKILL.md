---
name: agent-brief
description: Use when writing the prompt for a subagent that will change code or build a page, and when running two or more such agents at once. Gives the brief template, the few rules a subagent does not already load, and the limits for parallel lanes.
---

# Briefing a build agent

A subagent knows only its brief and the global rules file, which it loads by itself.
Do not retype global rules (dashes, co-author lines, `trash`, branches and pull requests) into a brief; point at this playbook's rules instead.

## Before spawning

- One agent per area of the code.
  Two agents editing the same files cost more in merges than they save.
- At most three build agents at once on this PC; check `free -h` and `uptime` first.
- Pick the model by the kind of work, and always name it in the spawn call so the agent does not inherit the session's model:
  - the most capable model only for structure, live multiplayer or concurrency, and a first-pass look;
  - the middle model for a build with a clear specification;
  - the small model for reading, searching and mechanical edits.
- One lane is one reviewable pull request.
  A lane that has passed a few hundred turns should be split: have it report, merge what is done, and start a fresh agent for the rest.
- Say the merge order when lanes will touch neighbouring code, and tell running lanes when the main branch moves.

## The brief

Write these, in this order, and nothing the agent can read for itself:

1. **Goal:** what the owner asked for, in their words where possible, and why.
2. **Done when:** the checks that must pass and what the owner must be able to try.
3. **Owns:** the folders and files this lane may change.
4. **Must not touch:** files owned by another running lane, generated files, changelogs.
5. **Where:** repository, base branch, branch name, worktree path (`~/worktrees/<repo>-<branch>`), and a port range of its own.
6. **Already known:** decisions made, what was ruled out, files and documents worth reading (paths, not pasted text).
7. **Report format:** what was built, exact test results with failures as failures, what was not checked, what the reviewer must look at.

## Rules every build agent gets

Paste this block, or tell the agent to load this playbook and follow the section:

```
- Test browsers run headless and muted, with no visible window on the owner's desktop.
- Do not spawn agents of your own.
- Commit after each working step and push the branch, so an interruption loses nothing.
- Never merge, deploy or publish; report and stop.
- Run tests in the foreground; never end your turn to wait on a background job you started.
- Before reporting, load the merge-and-cleanup playbook: stop servers and browsers you started, and say what you left running and why.
- When the command guard blocks a delete, a publish or anything touching secrets or permissions, stop and report it; do not retry another way.
- Never give the owner a local address; they review on a phone, through the live site or a hosted page.
```

## After a usage-limit cut-off or a restart

Agents that commit often lose nothing.
Resume each one by message with its last known state (branch, uncommitted files, the step it was on) instead of spawning a replacement.

## When an agent reports

- Its report is a claim, not a fact: read the diff and run the named tests before merging.
- An agent that says it is "waiting" on its own test run has stopped; message it to finish in the foreground.
- A finished agent whose standing instruction was to keep a server running will restart that server when you stop it.
  Tell it the work is merged and to end, then stop the server.

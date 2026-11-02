- Commit after every change: once a logical change/task is complete and verified, stage and commit it (don't let edits pile up uncommitted). Push when the user asks. Use clear messages.
- When writing commit messages, NEVER auto-add your agent name as co-author.
- Never use the em dash "—". Use plain dash "-" instead.
- Never manually modify CHANGELOG.md files or any files that are marked as auto-generated.
- When writing or substantially editing long Markdown files, put each full sentence on its own line. Preserve normal Markdown structure, but avoid wrapping multiple sentences onto one physical line.
- When making technical decisions, do not give much weight to development cost. Instead, prefer quality, simplicity, robustness, scalability, and long-term maintainability.
- When doing bug fixes, always start by reproducing the bug in an E2E setting as closely aligned with how an end user experiences it as possible. This makes sure you find the real problem so your fix will actually solve it.
- When end-to-end testing a product, be picky about the UI you see and be obsessed with pixel perfection. If something clearly looks off, even if it is not directly related to what you are doing, try to get it fixed along the way.
- Apply that same high standard to engineering excellence: lint, test failures, and test flakiness. If you see one, even if it is not caused by what you are working on right now, still get it fixed.
- For one-off or infrequent operational work, start with the simplest direct end-to-end path. Do not build wrappers, control planes, policy layers or automation unless the direct path exposes a concrete blocker or a repeated need that justifies it.
- Before using any harness feature that spawns a large swarm of subagents at once, explain the tradeoffs and ask the user for explicit approval.
- For taste-driven or sweeping UI changes, show a quick desktop preview (then mobile) with a localhost link and screenshots, and get approval before full responsive work, tests and polish. Small, clear fixes skip the preview.
- Deliver long reports, plans, status overviews and lists of decisions as a hosted HTML page (an Artifact) with a few lines plus the link in the terminal; keep quick updates and single questions in the terminal.
- Next.js: dev servers and test stacks run on Turbopack. Never add `--webpack` to `next dev` and never cap the heap with `NODE_OPTIONS=--max-old-space-size`; if something seems to need webpack, find out why first.
- To wait for a background job, use its completion notification, its exit code or a sentinel file. Never wait or kill with `pgrep -f`/`pkill -f` on a pattern that appears in your own command line: it matches itself.
- WSL username is `natkins`, Windows username is `natha`
- Windows C: drive is accessible from WSL at `/mnt/c/`
- Screenshots are at: `/mnt/c/Users/natha/OneDrive/Pictures/Screenshots`
- Downloads are at: `/mnt/c/Users/natha/Downloads`
- When the user shares a screenshot or says "check my screenshot", read the most recent file from the Screenshots path above

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session.
A procedure with a clear trigger belongs in a playbook (`~/.agents/skills/`), not here; a narrow rule with no trigger gets deleted.
Do not repeat what a codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.

- Commit after every change: once a logical change/task is complete and verified, stage and commit it (don't let edits pile up uncommitted). Push when the user asks. Use clear messages.
- Work on a branch and land it through a pull request, in every repo (private ones too) and for small fixes; never commit straight to the default branch. Private repos on the free plan have no branch protection, so this rule is the only guard.
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
- Security alerts on a transitive dependency: never force a new major with `overrides`/`resolutions`; the fix comes from updating the direct dependency that pulls it in. If no parent accepts the fix yet, dismiss the alert as "tolerable_risk" with a comment naming the blocking parent, and leave it to Dependabot's version updates.
- Never delete with `rm -rf` (or `rm`) anything you did not create in this task: move it with `trash PATH` instead (dotfiles `bin/trash`, kept 14 days in `~/.local/share/agent-trash/<date>/`, restore with `mv`). This covers other agents' and earlier sessions' files, scratch folders you didn't make, worktrees, and anything in the owner's folders. Say what you trashed and where.
- To wait for a background job, use its completion notification, its exit code or a sentinel file. Never wait or kill with `pgrep -f`/`pkill -f` on a pattern that appears in your own command line: it matches itself.
- WSL username is `natkins`, Windows username is `natha`
- Windows C: drive is accessible from WSL at `/mnt/c/`
- Screenshots are at: `/mnt/c/Users/natha/OneDrive/Pictures/Screenshots`
- Downloads are at: `/mnt/c/Users/natha/Downloads`
- When the user shares a screenshot or says "check my screenshot", read the most recent file from the Screenshots path above
- Secrets live in `pass`, used only through `pass-env`; you know them by name (`shared/GEMINI_API_KEY`), never by value. Never open `.env*`, `.dev.vars`, `~/.password-store` or `~/.gnupg`, never print secret variables, never ask the owner to paste a key into chat, and never work around a denied command.
- Each project lists its secrets by name in `.env.pass`. Run with `pass-env run -- <command>`, send one key with `pass-env pipe <entry> -- <command reading stdin>`, check with `pass-env check`; run and pipe go through for the known deploy and test tools and `gh secret set`, and ask the owner for anything else. Create keys we control with `pass-env generate <entry>`; for provider-issued keys ask the owner to run `! pass-env set <entry>`. If you see LOCKED, ask the owner to run `! pass-env unlock`.
- When dcg, a hook or a permission rule blocks or denies a command, decide whether the block is about the effect or only the method.
  - Effect (a real block): the command deletes data, publishes or releases, reveals or moves a secret, changes permissions or access, or touches the secrets store, backups or Windows Hello.
    Stop and report it (to the owner, or to the agent that started you): the command, the message, and what you were trying to do.
    Never retry it in another form (another tool, a script, an interpreter, a full path, a wrapper), including a "safer" form the block message itself suggests, until the owner says how to proceed.
  - Method: the action is harmless and only the way it was run tripped the guard.
    Do it with the dedicated tool instead, and say in your report what was blocked and what you used.
    Edit or create a file with the Edit or Write tool, not a shell heredoc or script.
    Send output to a literal path in the scratchpad, not a redirect to a path built from a variable.
    Read a file with the Read tool and search with the Grep tool, not a shell command.
    Put long PR or commit text in a file written with Write and pass it with `--body-file` or `-F`.
  - Never use a different method to get an effect that was blocked, and never run `agent-lock approve` or `dcg allow-once`.
    When unsure which kind a block is, treat it as a real block.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session.
A procedure with a clear trigger belongs in a playbook (`~/.agents/skills/`), not here; a narrow rule with no trigger gets deleted.
Do not repeat what a codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.

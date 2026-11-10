# dotfiles

How my coding agents (Claude Code and Codex) are set up: the rules every session reads, the playbooks they follow for specific situations, and the hooks that guard destructive commands.

## What's here

| Path | What it is | Where it goes |
| --- | --- | --- |
| `home/AGENTS.md` | The short rules every agent reads at the start of every session. | `~/AGENTS.md`, linked as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` |
| `skills/` | Playbooks: step-by-step procedures an agent loads only when the situation comes up. | `~/.agents/skills/`, linked into `~/.claude/skills/` and `~/.codex/skills/` |
| `home/.claude/settings.json` | Claude Code settings: permission prompts, hooks, status line. | Copied to `~/.claude/settings.json` |
| `home/.claude/hooks/` | `confirm-destructive-git.sh`: asks before repo deletes, secret changes, permission changes, force pushes, and `pass-env`/`hushkey` `run`/`pipe` to anything but the known deploy and test tools (inline code, script paths and custom configs ask). It also asks before `--no-mask`, restic, the Hushkey backup files, unit and script, Windows Hello unlocks and helper runs, R2 bucket deletes and lock changes, and releases (v* tags, `gh release`, publish, release scripts). Tests: `confirm-destructive-git.test.sh`, which also checks the settings.json permission rules. | `~/.claude/hooks/` |
| `bin/` | `trash` (move instead of delete) and `agent-lock` (the config lock). | `~/.local/bin/` |
| `home/.config/dcg/` | Destructive command guard settings, exceptions and the `n8` rule pack for my databases and hosts. | `~/.config/dcg/` |
| `home/.codex/config.hooks.toml` | The dcg hook for Codex. | A marked block inside `~/.codex/config.toml` |
| `home/.codex/rules/guardrails.rules` | Codex command rules mirroring the Claude permission rules where a fixed command prefix can express them. Tests: `guardrails.test.sh`. | `~/.codex/rules/guardrails.rules` |
| `home/.npmrc`, `home/.config/pnpm/config.yaml` | Install cooldown: npm and pnpm only pick package versions published at least 3 days ago. | A marked block inside `~/.npmrc` and `~/.config/pnpm/config.yaml` |
| `home/.config/agent-hooks/` | Hooks shared by Claude and Codex (keep `AGENTS.md` as the real file, remind to commit). | `~/.config/agent-hooks/` |

## Playbooks use the open skill format

Each playbook is a folder with a `SKILL.md`: a name, a one-line description of when to use it, and the steps.
That is the [Agent Skills](https://agentskills.io) open standard, which Claude Code, Codex, Gemini CLI, Cursor, GitHub Copilot and other agents read, so one playbook works everywhere.
Only the description sits in an agent's context every session; the steps load when a task matches, which keeps the always-on rules short.

| Playbook | Use it when |
| --- | --- |
| `github-access` | Deleting a repo, changing the `gh` login's permissions, touching repo secrets. |
| `go-public` | Making a private repo public (scan the whole history for secrets first). |
| `retire-repo` | Archiving, backlogging or deleting a project without losing anything. |
| `merge-and-cleanup` | Squash-merging PRs (release notes, parallel PRs, stacked PRs) and cleaning up afterwards. |
| `windows-testing` | Hands-on tests on the live Windows PC without disrupting the owner. |
| `writing` | Drafting anything published in my name; includes a draft `VOICE.md`. |
| `app-quality-bar` | Building, redesigning or reviewing the UI/UX of one of my web apps. |
| `demo-recording` | Recording or reviewing an automated product demo clip of an extension or web app. |

## Rules for this repo

- Keep `AGENTS.md` short: only what helps almost every session. A procedure with a clear trigger becomes a playbook; a narrow rule with no trigger gets deleted.
- No secrets, ever. They live in `pass` and load through [pass-env](https://github.com/n8watkins/pass-env). The secret scan workflow fails any push that contains one.
- Settings are copied, not linked, because Claude Code rewrites its settings file; `install.sh` tells you when your live copy has drifted.

## Destructive command guard

[dcg](https://github.com/Dicklesworthstone/destructive_command_guard) runs before every shell command in Claude Code and Codex and blocks the ones that destroy data: `git reset --hard`, `rm -rf` outside temp folders, dropping database tables, deleting Cloudflare Workers, D1 databases and R2 buckets, and more.
It parses the command, so wrappers (`sudo`, `bash -c`, `&&` chains) do not hide anything, and text that only mentions a command (commit messages, PR bodies, `grep`) passes.
It blocks rather than asks, also in bypass mode, and tells the agent to stop and ask me.

| File | What it does |
| --- | --- |
| `home/.config/dcg/config.toml` | Turns on the packs for SQLite, PostgreSQL, Supabase, Cloudflare Workers, GitHub and GitHub Actions; every match blocks. Lets `rm -rf` of build caches (`.next`, `node_modules/.cache`, `dist`, `.turbo`, `coverage`, `playwright-report`, `test-results`) through, also inside a longer command: by full path inside `~/n8builds/worktrees/*` and `~/projects/worktrees/*`, or by bare name. |
| `home/.config/dcg/packs/n8.yaml` | Rules dcg lacks for my stack: D1 `execute` with DROP, DELETE or TRUNCATE or a remote `--file`, D1 time-travel restore, `turso db shell` destructive SQL, `turso db/group destroy`, `drizzle-kit push/drop`, `prisma migrate reset`, `prisma db push --force-reset/--accept-data-loss`, Vercel removes, unpublishing a package, `agent-lock approve`, and `dcg allow-once`/`allowlist add` so an agent cannot lift a block itself. The last two match only where a command starts, so a heredoc or string that mentions them passes. |
| `home/.config/dcg/allowlist.toml` | Exceptions: `git branch -D`, `rm -rf` of build folders (`node_modules`, `dist`, `.next` and similar), a `git mv "$f" <folder>` loop, branch deletes through the API, cancelling a CI run, and the GitHub deletes that `confirm-destructive-git.sh` and the `ask` rules already confirm with me. |
| `home/.config/dcg/packs/n8.test.sh` | Tests through the same hook payload Claude Code sends, in bypass mode. CI runs them. |

`confirm-destructive-git.sh` keeps doing its job next to dcg: it asks about GitHub deletes, Actions secrets, login permissions, force pushes, and secrets handed to commands outside the known deploy and test tools.
When both answer, the stricter answer wins.

To override a block (owner only):

- Run the command yourself, in a terminal or with `!` in the Claude Code prompt (hooks do not see those).
- Or approve that exact command once: the denial ends with a code, and `! dcg allow-once <code>` lets it through one time.
- To see why something is blocked: `dcg explain -- "<command>"`.
- For a lasting exception, add it to `allowlist.toml` through a PR here.

Agents cannot do any of these: the n8 pack blocks `dcg allow-once`, `dcg allowlist add` and `dcg uninstall`.
A determined agent could still write the command into a script and run that; dcg is a guardrail, not a sandbox.
dcg also refuses some heredocs piped into `python3 -` or a shell that it cannot verify, and redirects to a path built from a variable.
Those blocks stay, because the same rules catch real commands hidden in a bash heredoc.
`AGENTS.md` tells agents to tell these method blocks apart from real ones and use their Edit, Write, Read and Grep tools instead, saying so in their report.

Install the binary (it is not kept in this repo, since its license carries a rider that must travel with every copy):

```bash
gh release download v0.16.0 -R Dicklesworthstone/destructive_command_guard -p 'dcg-x86_64-unknown-linux-musl.tar.xz*'
sha256sum -c dcg-x86_64-unknown-linux-musl.tar.xz.sha256
tar -xJf dcg-x86_64-unknown-linux-musl.tar.xz && install -m 755 dcg ~/.local/bin/dcg
```

The Claude Code hook is in `home/.claude/settings.json`.
For Codex, `install.sh` adds the hook to `~/.codex/config.toml`; open Codex once and approve it under `/hooks`, or Codex skips it.
A typical check takes 15 to 35 ms (dcg 0.16.0 on this machine); `git add` takes about 60 ms.
Claude Code runs both PreToolUse hooks at the same time, so they do not add up.

## Config lock

`bin/agent-lock` notices when agent config changes without my OK.
It covers what makes an agent run or trust something: Claude Code and Codex hooks, permissions, env, status line, MCP servers, plugins, skills, `CLAUDE.md`/`AGENTS.md`, Codex rules, the dcg config, and a repo's own `.claude/settings*.json`, `.mcp.json`, `.vscode/tasks.json` and `.codex/config.toml`.

- At every session start (Claude Code and Codex), it compares them with the approved snapshot and shows me and the agent what changed.
- A change that matches this repo's `main` branch came through a PR, so it is approved on its own.
- During a Claude Code session, the `ConfigChange` hook keeps an unapproved new hook, env var, plugin or skill from taking effect until the next session, where it is reported. Claude Code shows no message for that, so the next session start is where you hear about it. Permission changes go through, since I make those from the prompt.
- After a change you meant to make outside a PR, approve the current state: `! agent-lock approve` (in a repo, this also approves that repo's agent config).
- `agent-lock check` lists what is not approved yet.

The snapshot in `~/.local/state/agent-lock/` holds fingerprints and names only, never env values or MCP settings.
dcg blocks agents from running `agent-lock approve`; an agent that edits the snapshot file directly is not stopped, so this is a tripwire, not a lock.
Tests: `bin/agent-lock.test.sh`.

## Install cooldown

A hijacked npm release is usually spotted and pulled within a day or two.
With the cooldown, npm and pnpm resolve every range to a version that is at least 3 days old, so an agent cannot install one in that window.
Lockfile installs (`npm ci`, `pnpm install --frozen-lockfile`) are not affected, and Dependabot uses the same 3-day default.

To adopt a new release early, turn the window off for that one command:

```bash
npm install -D typescript@7 --min-release-age=0
pnpm add -D typescript@7 --config.minimumReleaseAge=0
```

Prefer the one-off flag over a permanent exclusion: an excluded package would also let a hijacked patch through on day one.
pnpm needs 10.16 or newer for this setting; older versions ignore it.

These files hold only settings.
`install.sh` writes them as a marked block into the live files instead of linking them, because npm saves login tokens to `~/.npmrc` and that must never end up in this public repo.

## Install

```bash
git clone https://github.com/n8watkins/dotfiles.git ~/projects/dotfiles
~/projects/dotfiles/install.sh
```

Existing files are moved aside to `<file>.pre-dotfiles` the first time.

## Inspired by

[Kun Chen's dotfiles](https://github.com/kunchenguid/dotfiles) and his post on [treating AGENTS.md like a trained model](https://blog.kunchenguid.com/p/your-agentsmd-is-a-neural-net).

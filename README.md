# dotfiles

How my coding agents (Claude Code and Codex) are set up: the rules every session reads, the playbooks they follow for specific situations, and the hooks that guard destructive commands.

## What's here

| Path | What it is | Where it goes |
| --- | --- | --- |
| `home/AGENTS.md` | The short rules every agent reads at the start of every session. | `~/AGENTS.md`, linked as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` |
| `skills/` | Playbooks: step-by-step procedures an agent loads only when the situation comes up. | `~/.agents/skills/`, linked into `~/.claude/skills/` and `~/.codex/skills/` |
| `home/.claude/settings.json` | Claude Code settings: permission prompts, hooks, status line. | Copied to `~/.claude/settings.json` |
| `home/.claude/hooks/` | `confirm-destructive-git.sh`: asks before repo deletes, secret changes, permission changes and force pushes. | `~/.claude/hooks/` |
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

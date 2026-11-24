# dotfiles

How my coding agents (Claude Code and Codex) are set up: the rules every session reads, the playbooks they follow for specific situations, and the hooks that guard destructive commands.

## What's here

| Path | What it is | Where it goes |
| --- | --- | --- |
| `home/AGENTS.md` | The short rules every agent reads at the start of every session. | `~/AGENTS.md`, linked as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` |
| `skills/` | Playbooks: step-by-step procedures an agent loads only when the situation comes up. | `~/.agents/skills/`, linked into `~/.claude/skills/` and `~/.codex/skills/` |
| `home/.claude/settings.json` | Claude Code settings: permission prompts, hooks, status line, and 90 days of session logs (`cleanupPeriodDays`; the default is 30) so [VibeLog](https://github.com/n8watkins/vibelog) can read them. The read-only `vibe today`, `vibe week` and `vibe standup` reports run without a prompt. | Copied to `~/.claude/settings.json` |
| `home/.claude/hooks/` | `confirm-destructive-git.sh`: asks before repo deletes, secret changes, permission changes, force pushes, and `pass-env`/`hushkey` `run`/`pipe` to anything but the known deploy and test tools (inline code, script paths and custom configs ask). It also asks before `--no-mask`, restic, the Hushkey backup files, unit and script, Windows Hello unlocks and helper runs, R2 bucket deletes and lock changes, and releases (v* tags, `gh release`, publish, release scripts). Tests: `confirm-destructive-git.test.sh`, which also checks the settings.json permission rules. `confirm-cloudflare-delete.sh`: asks before the Cloudflare connector's `execute` tool runs code that deletes or cannot be undone (see below). Tests: `confirm-cloudflare-delete.test.sh`. | `~/.claude/hooks/` |
| `bin/` | `trash` (move instead of delete), `agent-lock` (the config lock) and `gpu-run` (measure and log jobs on the graphics card; see below). | `~/.local/bin/` |
| `home/.config/systemd/user/` | `agent-trash-purge.timer` and its service: once a day they run `trash --purge`, so trash past its 3-day hold is deleted even in a week when no agent trashes anything. `install.sh` switches the timer on. | `~/.config/systemd/user/` |
| `home/.config/dcg/` | Destructive command guard settings, exceptions and the `n8` rule pack for my databases and hosts. | `~/.config/dcg/` |
| `home/.codex/config.hooks.toml` | Codex registrations for dcg, the shared guard adapter, instruction normalization, the commit reminder and the startup config check. | A marked block inside `~/.codex/config.toml` |
| `home/.codex/rules/guardrails.rules` | Codex command rules mirroring the Claude permission rules where a fixed command prefix can express them. Tests: `guardrails.test.sh`. | `~/.codex/rules/guardrails.rules` |
| `home/.npmrc`, `home/.config/pnpm/config.yaml` | Install cooldown: npm and pnpm only pick package versions published at least 3 days ago. | A marked block inside `~/.npmrc` and `~/.config/pnpm/config.yaml` |
| `home/.config/agent-hooks/` | Shared lifecycle hooks and the Codex adapter for the existing Git and Cloudflare guard scripts. | `~/.config/agent-hooks/` |

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
| `handoff` | Handing work to a fresh session: a status file, a kickoff file, and a one-line prompt that names it. |
| `agent-brief` | Writing the prompt for a build subagent, and running several at once. |
| `owner-preview` | Building a page the owner picks options from; delivered hosted, for a phone. |
| `publish-review` | Having a reviewer agent read every line of a page before it is published. |
| `gpu-jobs` | Running a render, a browser test, a model or any other job on the PC's graphics card. |
| `cloudflare-access` | Changing anything in Cloudflare through the connector or `wrangler`, and exporting data before a delete. |

## Rules for this repo

- Keep `AGENTS.md` short: only what helps almost every session. A procedure with a clear trigger becomes a playbook; a narrow rule with no trigger gets deleted.
- No secrets, ever. They live in `pass` and load through [pass-env](https://github.com/n8watkins/pass-env). The secret scan workflow fails any push that contains one.
- Settings are copied, not linked, because Claude Code rewrites its settings file; `install.sh` tells you when your live copy has drifted.

## Claude and Codex parity

Both agents use the same 14 playbooks and global instructions.
The aim is the same working habits and safety decisions, while respecting each harness's tool and permission model.
There is no automatic no-mistakes pipeline or new validation Stop hook.
Repository checks remain part of doing the work; the existing Stop hook only reminds the agent about uncommitted changes.

| Behavior | Claude Code | Codex |
| --- | --- | --- |
| Normalize project instructions and remind to commit | Shared lifecycle scripts | Same scripts |
| Destructive shell commands | dcg plus the Git guard | dcg plus the same Git guard through the adapter |
| Matching Cloudflare MCP execute calls | Cloudflare guard asks | Same guard through the adapter denies |
| Configuration changes | Startup check and ConfigChange hook | Startup check; no equivalent ConfigChange hook is registered |
| Hook activation | Settings registration | Registration plus owner trust in `/hooks` |

The Codex adapter converts an ask decision into a supported denial.
It does not approve calls, copy the parser logic or treat Codex's permission mode as Claude's auto-mode classifier.
If the selected guard crashes, returns invalid output or exceeds the adapter's deadline, the adapter denies the call.
The Codex registrations also block on a missing guard script or interpreter through an exit-2 shell fallback.
An outer harness timeout or failure to start the hook shell can still fail open; these scripts are guardrails, not a sandbox.
See [Codex's hook contract](https://learn.chatgpt.com/docs/hooks) for the trust and decision semantics.

After an adapter denial, the agent reports the exact operation and reason and stops.
The owner can perform an approved operation in their own terminal, then ask the agent to verify the result.
Approval in chat does not change a hook denial, and the agent must not switch tools or rewrite the command to get around it.
The `dcg allow-once` mechanism below applies only to a dcg denial, not an adapter denial.

Codex 0.163.0 can send a shell hook the session directory rather than the individual command's working directory.
Use `git -C <repo>` for directory-sensitive Git operations and explicit paths for configuration files.
The Cloudflare adapter accepts both `cloudflare-api__execute` and Codex's normalized `cloudflare_api__execute` suffixes on MCP tool names.
Another connector name or arbitrary HTTP client is not covered by that matcher.

### Skill portability

The shared playbooks already cover the owner's cross-agent workflows.
Additional local Claude skills are not copied wholesale into dotfiles:

| Local skill | Decision |
| --- | --- |
| `gh-axi` | Keep optional. The existing GitHub connector or `gh` supports the workflow, and the command guard does not treat every alternate CLI as equivalent to `gh`. Its raw-secret example must not replace `pass-env pipe`. |
| `chrome-devtools-axi` | Keep optional. Use the browser tool available in the current harness, with the existing Windows and GPU playbooks when applicable. |
| `gnhf` | Keep tied to an explicitly requested GNHF run rather than ordinary coding tasks. |
| `prev-req` | Keep Claude-specific; it searches Claude transcripts and must not claim to locate a Codex session. |
| `sentry-cli` | Keep optional for Sentry work. Check the installed CLI before adopting its large command reference. |
| `no-mistakes` | Leave on demand and managed by its existing installation; it is not a prerequisite for normal work. |

Handoff, browser-testing and preview playbooks keep their existing task triggers.
Shared file content gives both agents the same guidance, but does not guarantee identical automatic skill selection.

## Destructive command guard

[dcg](https://github.com/Dicklesworthstone/destructive_command_guard) runs before every shell command in Claude Code and Codex and blocks the ones that destroy data: `git reset --hard`, `rm -rf` outside temp folders, dropping database tables, deleting Cloudflare Workers, D1 databases and R2 buckets, and more.
It parses the command, so wrappers (`sudo`, `bash -c`, `&&` chains) do not hide anything, and text that only mentions a command (commit messages, PR bodies, `grep`) passes.
It blocks rather than asks, also in bypass mode, and tells the agent to stop and ask me.

| File | What it does |
| --- | --- |
| `home/.config/dcg/config.toml` | Turns on the packs for SQLite, PostgreSQL, Supabase, Cloudflare Workers, GitHub and GitHub Actions; every match blocks. Lets `rm -rf` of build caches (`.next`, `node_modules/.cache`, `dist`, `.turbo`, `coverage`, `playwright-report`, `test-results`) through, also inside a longer command: by full path inside `~/n8builds/worktrees/*` and `~/worktrees/*`, or by bare name. |
| `home/.config/dcg/packs/n8.yaml` | Rules dcg lacks for my stack: D1 `execute` with DROP, DELETE or TRUNCATE or a remote `--file`, D1 time-travel restore, `turso db shell` destructive SQL, `turso db/group destroy`, `drizzle-kit push/drop`, `prisma migrate reset`, `prisma db push --force-reset/--accept-data-loss`, Vercel removes, unpublishing a package, `agent-lock approve`, and `dcg allow-once`/`allowlist add` so an agent cannot lift a block itself. The last two match only where a command starts, so a heredoc or string that mentions them passes. |
| `home/.config/dcg/allowlist.toml` | Exceptions: `git branch -D`, `rm -rf` of build folders (`node_modules`, `dist`, `.next` and similar), a `git mv "$f" <folder>` loop, branch deletes through the API, cancelling a CI run, and the GitHub deletes that `confirm-destructive-git.sh` and the `ask` rules already confirm with me. |
| `home/.config/dcg/packs/n8.test.sh` | Tests through the same hook payload Claude Code sends, in bypass mode. CI runs them. |

`confirm-destructive-git.sh` keeps doing its job next to dcg: it asks about GitHub deletes, Actions secrets, login permissions, force pushes, and secrets handed to commands outside the known deploy and test tools.
When both answer, the stricter answer wins.

## Cloudflare connector guard

The Cloudflare MCP connector gives agents write access to the whole account, and Cloudflare has no "may edit, may not delete" permission.
Its `execute` tool runs a JavaScript function that calls `cloudflare.request({ method, path, body })`, so `confirm-cloudflare-delete.sh` reads that code before it runs (it matches any tool whose name ends in `cloudflare-api__execute`, whatever the plugin prefix).

- It asks before any DELETE request (any case, quoting or escape such as `"DELETE"`), naming the paths it can read.
- It reads constants, concatenations and ternaries of literals, and asks when a method still cannot be read as GET, POST, PUT or PATCH: a variable it cannot follow to one literal, a call, a getter, a repeated `method` key.
- A backstop asks when the code could set a method where the reader does not look: a string that is exactly DELETE outside a plain key value or comparison, JSON text with `"method":"DELETE"`, a computed key on a request object, or `eval`, `Function`, `Reflect`, `defineProperty`, `fromEntries`, `fromCharCode` or `atob`.
- It asks for the calls in the `DESTRUCTIVE` table at the top of the script, matched against each request's own path (concatenations and templates included): purging a zone's whole cache; DROP, DELETE, TRUNCATE or an UPDATE without WHERE in the SQL sent to D1; D1 restore and import; R2 lifecycle and lock rules; a Worker upload (Workers for Platforms too) whose migrations carry `deleted_classes`; KV bulk delete; DNS batch deletes; Vectorize `delete_by_ids`; queue purge; turning off Email Routing; pausing a zone; whole-set replacements of a ruleset phase, a list's items or an Access app's policies; rotating a Turnstile secret; any Registrar or API token write; and sending email.
- It asks when it cannot parse the input, and it fails closed: its own errors ask, and the registration in `settings.json` sets `timeout: 10` and `onFailure: "block"` (Claude Code 2.1.295 or later), so a crash, a stall or a missing `python3` stops the call.
- Everything else passes silently: GET-only code, ordinary writes, and the word "delete" in a comment, key, key value, comparison, path segment, Worker source or a body other than D1 SQL.
  A call takes about 35 ms, a 1.2 MB Worker upload about 60 ms.

It reads the code without running it, so a method computed from pieces it cannot see (a value fetched at run time, char-code arithmetic without the names above) gets past it.
For `wrangler`, the `permissions.ask` rules in `settings.json` start at the launcher (`wrangler`, `npx`, `pnpm`, `bunx`, `bun`, `yarn`, `pass-env`, `hushkey`, `node_modules/.bin`) and ask before every `... delete`, `d1 execute --remote`, `d1 time-travel restore`, `queues purge`, `rollback` and R2 lifecycle and lock change, also with flags before the subcommand; text that only mentions wrangler (a commit message, `grep`) does not match.
`confirm-destructive-git.sh` also asks before `wrangler deploy` or `versions upload` when the config adds a `deleted_classes` migration that is not yet on the default branch.
The agent rules are in the `cloudflare-access` playbook.

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
- A change that matches this repo's `main` branch came through a PR, so it is approved on its own, unless it is safety-critical (below).
- Safety-critical config always waits for `! agent-lock approve`, even when it matches `main`, because agents can merge PRs here and could otherwise approve their own rule change.
  It covers: the `hooks`, `permissions`, `disableAllHooks` and `sandbox` keys of `~/.claude/settings.json` (and `settings.local.json`), the hook scripts in `~/.claude/hooks/` and `~/.config/agent-hooks/`, the dcg config, allowlist and rule packs, `AGENTS.md`/`CLAUDE.md`, `~/.codex/rules/*`, the Codex hooks in `config.toml`, and `agent-lock` itself (`~/.local/bin/agent-lock`, which holds the list).
  `agent-lock check` and the session-start message mark each one `(safety-critical)`, add `matches dotfiles main` when it came through a PR, and list them first.
  Skills, plugins, MCP servers, the status line and the other settings keys keep the `main` auto-approval.
- The snapshot keeps the safety-critical list as last approved, and checks use it together with the script's own list: a changed list shows as `agent-lock:safety-list` with what was added or removed, and an entry taken out of the script still counts until the owner approves.
- During a Claude Code session, the `ConfigChange` hook keeps an unapproved new hook, env var, plugin or skill from taking effect until the next session, where it is reported. Claude Code shows no message for that, so the next session start is where you hear about it. Permission changes go through, since I make those from the prompt.
- After a change you meant to make outside a PR, approve the current state: `! agent-lock approve` (in a repo, this also approves that repo's agent config).
- `agent-lock check` lists what is not approved yet.

The snapshot in `~/.local/state/agent-lock/` holds fingerprints and names only, never env values or MCP settings.
dcg blocks agents from running `agent-lock approve`; an agent that edits the snapshot file directly is not stopped, and a merged rewrite of `agent-lock` that hides its own change would only be caught in PR review, so this is a tripwire, not a lock.
Tests: `bin/agent-lock.test.sh`.

## GPU jobs

`bin/gpu-run` runs a command as a graphics-card job on a Windows PC with WSL and records what happened, so tuning the card's use rests on numbers instead of guesses.

```bash
gpu-run --label "room-pick suite" --kind browser-test -- node test/e2e.mjs
gpu-run --cpu --label "room-pick suite" --kind browser-test -- node test/e2e.mjs   # the same job in software
gpu-run --watch 30 --label "desktop at rest"
gpu-run --report --since 2026-11-01
gpu-run --off "driver error during a render"   # every GPU job refuses until --on
```

- It counts browsers that may draw at once, not jobs: a pool of tokens (`/tmp/test-gpu-<n>.lock`, n = 1 to `TEST_GPU_JOBS`, default 3, plain `flock` files).
  A job takes one token, or `--tokens N`; `--kind blender`, `image` or `model` takes every token.
  Tokens are taken all at once or not at all, so nothing deadlocks; a gate file lets a job waiting for several go before single-token jobs that come after it, for at most three minutes at a time, and a gate held for ten minutes is passed by.
  A job that waits long says who holds the tokens (pid, label, how long), as the holders write it into the lock files.
  A token is held shared after an exclusive check; the party-games test helper and a `gpu-run` inside the job hold it shared too, so it stays taken while anything of the job that draws still runs, even after `gpu-run` itself is killed.
  The command does not inherit the lock, so a background process it leaves (a dev server started with `&`) holds no token; a leftover that does hold one is named loudly when the job ends and logged (`left_holding`), and a waiting job names every holder from `/proc/locks`.
  The command gets the tokens in `TEST_GPU_TOKENS`, and the party-games test helper or a `gpu-run` inside it claims one of those (a `<token>.use` lock, plus a shared hold on the token) instead of taking more from the pool.
  It refuses while `TEST_NO_GPU=1` is set or the off marker exists.
- Admission: before it takes its tokens, a job waits until the card can take it (load averaged under 70% over the last 10 s, 2 GB of video memory free, under 80 C, no display driver event in the last 30 minutes, a late processed report counting from the first), says why, and gives up with exit 6 after `--admit-wait` seconds (default 2700), leaving a log record; `--admit-timeout-runs` starts anyway with a loud line instead.
  Every sampler publishes its recent readings in `~/.local/state/gpu/live/`, so while another job runs the check costs nothing; otherwise the job's own sampler takes about ten seconds.
- One long-lived PowerShell process reads the Windows GPU counters every two seconds (overall load, video memory, top processes by video memory) for the adapter named in `GPU_RUN_ADAPTER` (default `RX 7800`), found through its LUID in the DirectX registry keys, and the same adapter's temperature and fan speed (the adapter performance data Task Manager reads).
  A sample costs a few milliseconds after a first read of about five seconds; no window is shown.
- `--max-temp <C>` (above 0, at most 110) refuses (exit 5) while the card is hotter than that, and stops the job (exit 5) after three readings in a row above it; one hot reading or a missing one does not stop it.
- At the end it checks the Windows logs for display driver timeouts and graphics crashes in the job's time window, appends one JSON line to `~/.local/state/gpu/jobs.jsonl` (no environment, home shortened to `~`) and prints three lines.
  A driver event inside the job's window writes the off marker, naming the event, so the next job refuses until `gpu-run --on`.
- `--only-when-idle <minutes>` refuses unless nobody has touched the PC for that long and nothing runs full screen.

Tests (no card needed, a fake sampler): `bin/gpu-run.test.sh`.
The agent rules for using it are in the `gpu-jobs` playbook.

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
git clone https://github.com/n8watkins/dotfiles.git ~/dotfiles
~/dotfiles/install.sh
```

Existing files are moved aside to `<file>.pre-dotfiles` the first time.

The installer requires Python 3.11 or later for TOML validation.
It migrates the known earlier Codex lifecycle registrations into the managed block without duplicating them and leaves unrelated settings and trust records intact.
Customized hook groups, ambiguous markers or relocation of a custom hook with saved positional state stop the migration with an error; inspect that configuration before trying again.
It never grants hook trust.
After installation, review all hooks in Codex's `/hooks` menu, including the dcg, guard adapter and startup config check, then restart the session.
Review any safety-critical changes reported by `agent-lock` in the owner's terminal before approving them.
Do not run the installer from an unmerged worktree against the live home: installed symlinks would then follow that branch.

The full installer can be checked in a disposable directory with `install.sh --target-home /absolute/fixture/path`.
This is an installation test destination, not a replacement for the real home or a way to grant trust.
The fixture tests are `python3 -I scripts/install-codex-hooks.test.py`.

## Inspired by

[Kun Chen's dotfiles](https://github.com/kunchenguid/dotfiles) and his post on [treating AGENTS.md like a trained model](https://blog.kunchenguid.com/p/your-agentsmd-is-a-neural-net).

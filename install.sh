#!/usr/bin/env bash
# Links this repo's files into place. Safe to re-run: existing files are moved
# aside to <file>.pre-dotfiles once, and links already pointing here are kept.
set -euo pipefail
repo="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then
  target_home="$HOME"
elif [ "$#" -eq 2 ] && [ "$1" = "--target-home" ] && [[ "$2" = /* ]]; then
  target_home="$2"
else
  echo "usage: install.sh [--target-home /absolute/path]" >&2
  exit 2
fi

link() { # link <repo path> <target>
  local src="$repo/$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then return; fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then mv "$dst" "$dst.pre-dotfiles"; fi
  ln -s "$src" "$dst"
  echo "linked $dst"
}

# block <repo path> <target>: keeps the repo file's lines inside a marked block
# in the target and leaves everything else alone. Used for files that tools
# also write to themselves (npm stores login tokens in ~/.npmrc), so the live
# file must never be a link into this public repo.
block() {
  local src="$repo/$1" dst="$2" begin="# >>> dotfiles: $1 >>>" end="# <<< dotfiles: $1 <<<"
  mkdir -p "$(dirname "$dst")"
  touch "$dst"
  local tmp; tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$dst" >"$tmp"
  { cat "$tmp"; echo "$begin"; cat "$src"; echo "$end"; } >"$tmp.new"
  if ! cmp -s "$tmp.new" "$dst"; then cat "$tmp.new" >"$dst"; echo "updated $dst"; fi
  rm -f "$tmp" "$tmp.new"
}

# One rules file for every agent.
link home/AGENTS.md "$target_home/AGENTS.md"
link home/AGENTS.md "$target_home/.claude/CLAUDE.md"
link home/AGENTS.md "$target_home/.codex/AGENTS.md"

# Package install cooldown (npm and pnpm).
block home/.npmrc "$target_home/.npmrc"
block home/.config/pnpm/config.yaml "$target_home/.config/pnpm/config.yaml"

# Hooks.
link home/.claude/hooks/confirm-destructive-git.sh "$target_home/.claude/hooks/confirm-destructive-git.sh"
link home/.claude/hooks/confirm-cloudflare-delete.sh "$target_home/.claude/hooks/confirm-cloudflare-delete.sh"
# Codex command rules (secrets, backup, Hello, releases). Codex reads every
# .rules file in ~/.codex/rules and writes its own approvals to default.rules.
link home/.codex/rules/guardrails.rules "$target_home/.codex/rules/guardrails.rules"

# Destructive command guard (dcg): settings, exceptions and the n8 rule pack.
link home/.config/dcg/config.toml "$target_home/.config/dcg/config.toml"
link home/.config/dcg/allowlist.toml "$target_home/.config/dcg/allowlist.toml"
for f in "$repo"/home/.config/dcg/packs/*.yaml; do
  link "home/.config/dcg/packs/$(basename "$f")" "$target_home/.config/dcg/packs/$(basename "$f")"
done
if [ ! -x "$target_home/.local/bin/dcg" ]; then
  echo "dcg is not installed at $target_home/.local/bin/dcg. Codex Bash calls will be blocked once the dcg hook is trusted."
fi
for f in "$repo"/bin/*; do
  case "$f" in *.test.sh) continue ;; esac
  link "bin/$(basename "$f")" "$target_home/.local/bin/$(basename "$f")"
done
for f in "$repo"/home/.config/agent-hooks/*.{sh,py}; do
  [ -f "$f" ] || continue
  case "$f" in *.test.sh|*.test.py|*_test.py|*/test_*.py) continue ;; esac
  link "home/.config/agent-hooks/$(basename "$f")" "$target_home/.config/agent-hooks/$(basename "$f")"
done

# Codex writes other settings and hook trust to this file.
python3 -I "$repo/scripts/install-codex-hooks.py" "$repo/home/.codex/config.hooks.toml" "$target_home"

# Playbooks: the shared skills folder, linked for Claude and Codex too.
for s in "$repo"/skills/*/; do
  name="$(basename "$s")"
  link "skills/$name" "$target_home/.agents/skills/$name"
  link "skills/$name" "$target_home/.claude/skills/$name"
  link "skills/$name" "$target_home/.codex/skills/$name"
done

# Claude settings are copied, not linked: Claude Code rewrites this file itself.
if [ ! -e "$target_home/.claude/settings.json" ]; then
  cp "$repo/home/.claude/settings.json" "$target_home/.claude/settings.json"
  echo "copied settings.json"
elif ! diff -q "$repo/home/.claude/settings.json" "$target_home/.claude/settings.json" >/dev/null; then
  echo "settings.json differs from the repo copy: diff $repo/home/.claude/settings.json $target_home/.claude/settings.json"
fi

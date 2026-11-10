#!/usr/bin/env bash
# Links this repo's files into place. Safe to re-run: existing files are moved
# aside to <file>.pre-dotfiles once, and links already pointing here are kept.
set -euo pipefail
repo="$(cd "$(dirname "$0")" && pwd)"

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
link home/AGENTS.md "$HOME/AGENTS.md"
link home/AGENTS.md "$HOME/.claude/CLAUDE.md"
link home/AGENTS.md "$HOME/.codex/AGENTS.md"

# Package install cooldown (npm and pnpm).
block home/.npmrc "$HOME/.npmrc"
block home/.config/pnpm/config.yaml "$HOME/.config/pnpm/config.yaml"

# Hooks.
link home/.claude/hooks/confirm-destructive-git.sh "$HOME/.claude/hooks/confirm-destructive-git.sh"
for f in "$repo"/bin/*; do
  link "bin/$(basename "$f")" "$HOME/.local/bin/$(basename "$f")"
done
for f in "$repo"/home/.config/agent-hooks/*.sh; do
  link "home/.config/agent-hooks/$(basename "$f")" "$HOME/.config/agent-hooks/$(basename "$f")"
done

# Playbooks: the shared skills folder, linked for Claude and Codex too.
for s in "$repo"/skills/*/; do
  name="$(basename "$s")"
  link "skills/$name" "$HOME/.agents/skills/$name"
  link "skills/$name" "$HOME/.claude/skills/$name"
  link "skills/$name" "$HOME/.codex/skills/$name"
done

# Claude settings are copied, not linked: Claude Code rewrites this file itself.
if [ ! -e "$HOME/.claude/settings.json" ]; then
  cp "$repo/home/.claude/settings.json" "$HOME/.claude/settings.json"
  echo "copied settings.json"
elif ! diff -q "$repo/home/.claude/settings.json" "$HOME/.claude/settings.json" >/dev/null; then
  echo "settings.json differs from the repo copy: diff $repo/home/.claude/settings.json ~/.claude/settings.json"
fi

#!/usr/bin/env bash
# Normalize a project's agent memory file so it is agent-agnostic:
#   AGENTS.md is the real file, CLAUDE.md is a symlink -> AGENTS.md
#
# Harness-agnostic: runs from Claude Code (SessionStart/Stop) and Codex
# (SessionStart/Stop). Idempotent and non-destructive: it never clobbers an
# existing real AGENTS.md and never creates empty files.
set -euo pipefail

# Determine the project directory across harnesses:
#   Claude Code exports CLAUDE_PROJECT_DIR.
#   Codex passes the hook payload as JSON on stdin with a "cwd" field.
# Fall back to $PWD.
dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$dir" ] && [ ! -t 0 ]; then
  input="$(cat 2>/dev/null || true)"
  dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -z "$dir" ] && dir="$PWD"

# Never touch the home dir itself or the harness config dirs.
case "$dir" in
  "$HOME" | "$HOME/.claude" | "$HOME/.claude/"* | "$HOME/.codex" | "$HOME/.codex/"* | "$HOME/.config/"*) exit 0 ;;
esac

cd "$dir" 2>/dev/null || exit 0

# A CLAUDE.md link this hook added must not make the repo look changed: an
# untracked file makes the checkout "dirty", so storage cleanup skips its build
# output and agents may commit the link by accident. List an untracked link in
# the repo's local, never-committed ignore file (.git/info/exclude). Leaves
# tracked links and non-git folders alone.
exclude_link() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git ls-files --error-unmatch -- CLAUDE.md >/dev/null 2>&1 && return 0
  local exclude entry
  exclude="$(git rev-parse --git-path info/exclude)" || return 0
  entry="/$(git rev-parse --show-prefix)CLAUDE.md"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF -- "$entry" "$exclude" 2>/dev/null || printf '%s\n' "$entry" >>"$exclude"
}

# Already correct: CLAUDE.md is a symlink pointing at AGENTS.md.
if [ -L CLAUDE.md ] && [ "$(readlink CLAUDE.md)" = "AGENTS.md" ]; then
  exclude_link
  exit 0
fi

# AGENTS.md exists as a real file, no CLAUDE.md yet -> just add the symlink.
if [ -f AGENTS.md ] && [ ! -L AGENTS.md ] && [ ! -e CLAUDE.md ]; then
  ln -s AGENTS.md CLAUDE.md
  exclude_link
  exit 0
fi

# A real (non-symlink) CLAUDE.md exists -> promote it to AGENTS.md + symlink,
# but only if that would not overwrite an existing real AGENTS.md.
if [ -f CLAUDE.md ] && [ ! -L CLAUDE.md ]; then
  if [ -e AGENTS.md ]; then
    # Both real files present. Don't guess which wins; leave it for the human.
    exit 0
  fi
  mv CLAUDE.md AGENTS.md
  ln -s AGENTS.md CLAUDE.md
  exit 0
fi

exit 0

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

# Already correct: CLAUDE.md is a symlink pointing at AGENTS.md.
if [ -L CLAUDE.md ] && [ "$(readlink CLAUDE.md)" = "AGENTS.md" ]; then
  exit 0
fi

# AGENTS.md exists as a real file, no CLAUDE.md yet -> just add the symlink.
if [ -f AGENTS.md ] && [ ! -L AGENTS.md ] && [ ! -e CLAUDE.md ]; then
  ln -s AGENTS.md CLAUDE.md
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

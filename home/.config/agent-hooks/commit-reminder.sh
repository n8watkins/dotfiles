#!/usr/bin/env bash
# Soft commit reminder (Stop hook). Harness-agnostic: works under Claude Code
# and Codex, both of which understand the {"systemMessage": ...} output.
#
# If the current project is a git repo with uncommitted changes, surface a
# short note when the agent stops. It NEVER commits and NEVER blocks the turn.
# Throttled to at most once per interval per repo so it does not nag on every
# turn during active work.
set -euo pipefail

# Determine the project directory across harnesses (see normalize script).
dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$dir" ] && [ ! -t 0 ]; then
  input="$(cat 2>/dev/null || true)"
  dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -z "$dir" ] && dir="$PWD"

cd "$dir" 2>/dev/null || exit 0

# Only inside a git work tree.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Nothing staged, unstaged, or untracked -> stay silent.
status="$(git status --porcelain 2>/dev/null)" || exit 0
[ -z "$status" ] && exit 0

# Throttle: at most once per interval (seconds) per repo path. Shared across
# harnesses, so Claude and Codex won't both nag within the same window.
interval=600
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/agent-commit-reminder"
mkdir -p "$cache_dir" 2>/dev/null || true
key="$(printf '%s' "$dir" | sha1sum | cut -d' ' -f1)"
marker="$cache_dir/$key"
now="$(date +%s)"
if [ -f "$marker" ]; then
  last="$(cat "$marker" 2>/dev/null || echo 0)"
  if [ $((now - last)) -lt "$interval" ]; then
    exit 0
  fi
fi
printf '%s' "$now" > "$marker" 2>/dev/null || true

count="$(printf '%s\n' "$status" | grep -c .)"
# git branch --show-current is empty on a detached HEAD or an unborn branch,
# and never errors, so it avoids the multi-line output rev-parse can produce.
branch="$(git branch --show-current 2>/dev/null)"
[ -z "$branch" ] && branch='(no branch yet)'
msg="Uncommitted changes: ${count} file(s) on branch ${branch}. Per AGENTS.md, commit once the change is complete and verified."
# Strip any stray newlines/control chars so the JSON string stays valid.
msg="$(printf '%s' "$msg" | tr -d '\r\n')"

printf '{"systemMessage": "%s", "suppressOutput": true}\n' "$msg"
exit 0

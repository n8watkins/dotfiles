#!/usr/bin/env bash
# Tests for normalize-agents-md.sh. Run: bash home/.config/agent-hooks/normalize-agents-md.test.sh
set -euo pipefail

hook="$(cd "$(dirname "$0")" && pwd)/normalize-agents-md.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

check() { # check <name> <command...>
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}

repo() { # repo <dir>: a git repo with a committed AGENTS.md
  mkdir -p "$1" && git -C "$1" init -q && printf '# rules\n' >"$1/AGENTS.md"
  git -C "$1" add AGENTS.md && git -C "$1" -c user.name=t -c user.email=t@t commit -qm init
}
run() { (cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$hook" </dev/null); }
clean() { [ -z "$(git -C "$1" status --porcelain)" ]; }

# 1. Adds the link and leaves the repo clean.
repo "$tmp/a"; run "$tmp/a"
check "link created" test "$(readlink "$tmp/a/CLAUDE.md")" = AGENTS.md
check "repo stays clean" clean "$tmp/a"

# 2. An existing untracked link (made before this fix) gets excluded too.
repo "$tmp/b"; ln -s AGENTS.md "$tmp/b/CLAUDE.md"
check "old link shows as untracked first" test -n "$(git -C "$tmp/b" status --porcelain)"
run "$tmp/b"
check "old link now ignored" clean "$tmp/b"

# 3. Running twice adds the exclude entry once.
run "$tmp/a"
check "exclude entry not duplicated" test "$(grep -cxF /CLAUDE.md "$tmp/a/.git/info/exclude")" = 1

# 4. A committed link is left alone (no exclude entry).
repo "$tmp/c"; ln -s AGENTS.md "$tmp/c/CLAUDE.md"
git -C "$tmp/c" add CLAUDE.md && git -C "$tmp/c" -c user.name=t -c user.email=t@t commit -qm link
run "$tmp/c"
check "tracked link not excluded" bash -c "! grep -qxF /CLAUDE.md '$tmp/c/.git/info/exclude'"

# 5. A subfolder project inside a repo gets a path-scoped entry.
repo "$tmp/d"; mkdir -p "$tmp/d/app" && printf '# app\n' >"$tmp/d/app/AGENTS.md"
git -C "$tmp/d" add app/AGENTS.md && git -C "$tmp/d" -c user.name=t -c user.email=t@t commit -qm app
run "$tmp/d/app"
check "subfolder entry" grep -qxF /app/CLAUDE.md "$tmp/d/.git/info/exclude"
check "subfolder repo clean" clean "$tmp/d"

# 6. A linked worktree uses the shared exclude file and stays clean.
repo "$tmp/e"; git -C "$tmp/e" worktree add -q "$tmp/e-wt" -b wt
run "$tmp/e-wt"
check "worktree clean" clean "$tmp/e-wt"

# 7. A plain folder (no git) still gets the link and no error.
mkdir -p "$tmp/f" && printf '# rules\n' >"$tmp/f/AGENTS.md"
run "$tmp/f"
check "non-git link created" test -L "$tmp/f/CLAUDE.md"

echo "$pass/$((pass + fail)) passed"
[ "$fail" -eq 0 ]

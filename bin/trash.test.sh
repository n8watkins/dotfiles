#!/usr/bin/env bash
# Tests for bin/trash: run `bash bin/trash.test.sh`. Everything happens in a temp folder.
set -euo pipefail

here="$(cd "$(dirname -- "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
export TRASH_DIR="$work/trash"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

today="$(date +%Y-%m-%d)"
ago() { date -d "$1 days ago" +%Y-%m-%d; }

# A worktree with what a command can rebuild, and things that only look like it.
src="$work/proj"
mkdir -p "$src/node_modules/a" "$src/packages/web/node_modules/b" "$src/packages/web/.next/cache" "$src/.turbo" \
  "$src/app/src-tauri/target/debug" "$src/docs/target" "$src/src"
echo "[package]" > "$src/app/src-tauri/Cargo.toml"
echo keep > "$src/src/index.js"
echo keep > "$src/docs/target/notes.md"
echo x > "$src/node_modules/a/x.js"
echo x > "$src/app/src-tauri/target/debug/bin"

out="$(bash "$here/trash" "$src")"
dest="$TRASH_DIR/$today$src"
check "the folder is moved to today's trash" '[ ! -e "$src" ] && [ -f "$dest/src/index.js" ]'
check "node_modules go, at every depth" '[ ! -e "$dest/node_modules" ] && [ ! -e "$dest/packages/web/node_modules" ]'
check ".next and .turbo go" '[ ! -e "$dest/packages/web/.next" ] && [ ! -e "$dest/.turbo" ]'
check "a Rust target beside a Cargo.toml goes" '[ ! -e "$dest/app/src-tauri/target" ] && [ -f "$dest/app/src-tauri/Cargo.toml" ]'
check "a folder merely named target stays" '[ -f "$dest/docs/target/notes.md" ]'
check "it says what it removed" 'grep -q "removed 5 rebuildable" <<<"$out"'

# TRASH_KEEP_ALL=1 keeps everything.
mkdir -p "$work/keep/node_modules/a"
TRASH_KEEP_ALL=1 bash "$here/trash" "$work/keep" > /dev/null
check "TRASH_KEEP_ALL=1 keeps node_modules" '[ -d "$TRASH_DIR/$today$work/keep/node_modules/a" ]'

# A folder that is itself node_modules is what was asked for: moved whole.
mkdir -p "$work/only/node_modules/pkg"
bash "$here/trash" "$work/only/node_modules" > /dev/null
check "a trashed node_modules itself is kept whole" '[ -d "$TRASH_DIR/$today$work/only/node_modules/pkg" ]'

# A single file is only moved.
echo hi > "$work/file.txt"
bash "$here/trash" "$work/file.txt" > /dev/null
check "a file is moved" '[ -f "$TRASH_DIR/$today$work/file.txt" ]'

# The hold: 3 days by the folder's name, whatever its mtime; other names are left alone.
mkdir -p "$TRASH_DIR/$(ago 3)/x" "$TRASH_DIR/$(ago 4)/x" "$TRASH_DIR/$(ago 30)/x" "$TRASH_DIR/not-a-date/x"
touch "$TRASH_DIR/$(ago 30)"
echo hi > "$work/again.txt"
bash "$here/trash" "$work/again.txt" > /dev/null
check "a day 3 days old is kept" '[ -d "$TRASH_DIR/$(ago 3)" ]'
check "a day 4 days old is purged" '[ ! -e "$TRASH_DIR/$(ago 4)" ]'
check "an old day touched just now is still purged" '[ ! -e "$TRASH_DIR/$(ago 30)" ]'
check "a folder that is not a date is left alone" '[ -d "$TRASH_DIR/not-a-date/x" ]'

# TRASH_KEEP_DAYS changes the hold.
mkdir -p "$TRASH_DIR/$(ago 2)/x"
echo hi > "$work/third.txt"
TRASH_KEEP_DAYS=1 bash "$here/trash" "$work/third.txt" > /dev/null
check "TRASH_KEEP_DAYS=1 purges a day 2 days old" '[ ! -e "$TRASH_DIR/$(ago 2)" ]'

# No arguments is a usage error; a missing path is reported and skipped.
if bash "$here/trash" > /dev/null 2>&1; then bad "no arguments exits non-zero"; else ok "no arguments exits non-zero"; fi
check "a missing path is reported" 'bash "$here/trash" "$work/nope" 2>&1 | grep -q "no such file"'

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

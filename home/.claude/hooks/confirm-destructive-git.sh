#!/usr/bin/env bash
# User-level PreToolUse guard (every project): commands that delete or overwrite
# things on GitHub, or rewrite pushed history, always need the owner's OK.
# Emits an "ask" decision as JSON; silence = no opinion (normal rules apply).
#
# Asks for: gh repo delete/archive, gh secret set/delete/remove, gh auth refresh
# (changes the login's permissions), gh api DELETE calls, plain force pushes
# (-f/--force/+refspec), --force-with-lease pushes to main or master, and
# pass-env/hushkey run/pipe to anything but the known tools, project scripts and
# secret sinks (see SAFE_SECRET_USES and secret_use_reason; in auto mode that one
# reason is left to the classifier), and pass-env/hushkey generate --copy.
# Launchers (npx, bunx, pnpm exec/dlx, npm exec, uv run) are looked through: the
# command they start gets every check a bare one gets.
# Hushkey (owner, 2026-11-10): run/pipe --no-mask, restic, the backup files,
# unit and script, Windows Hello unlock and helper runs, wrangler commands that
# delete, roll back, purge, restore or change exposure (2026-11-15), and
# releases (v* tags, gh release, publish, release scripts, gh api writes to
# pending_deployments, environments and rulesets).
# This hook only asks. Most of those are also denied for agents by the
# permission rules in settings.json; the hook is the second layer that reads
# commands the way bash does (bash -c, full paths, wrappers).
#
# Does not ask for (owner, 2026-11-09):
# - text that only mentions those commands (commit messages, PR bodies, heredocs,
#   quoted strings, scripts): only commands that actually run are checked; the
#   command is read like bash reads it, so quoted text may span lines and a
#   trailing backslash continues the command;
# - --force-with-lease to a feature branch (routine after a rebase);
# - deleting a branch through the API (gh api -X DELETE .../git/refs/heads/...),
#   same as `git push origin --delete` (owner, 2026-11-02).
#
# If the command cannot be parsed, it falls back to the old plain-text match,
# so a parse failure can only add a prompt, never remove one.
# Tests: home/.claude/hooks/confirm-destructive-git.test.sh
input=$(cat)
exec python3 -I -c '
import json, os, re, subprocess, sys

data = json.loads(sys.argv[1] or "{}")
cmd = (data.get("tool_input") or {}).get("command") or ""
cwd = data.get("cwd") or os.getcwd()

SHELLS = {"bash", "sh", "zsh", "dash"}
WRAPPERS = {"sudo", "env", "command", "time", "nohup", "exec", "builtin"}
PROTECTED = {"main", "master"}
KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "!", "{", "}"}

def strip_heredocs(text):
    """Drop heredoc bodies (data, not commands) unless a shell reads them."""
    out, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        m = re.search(r"<<(-?)\s*([\x27\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", line)
        i += 1
        if not m or "<<<" in line:
            continue
        dash, tag = m.group(1), m.group(3)
        feeds_shell = re.search(r"(^|[\s;&|(])(bash|sh|zsh|dash)(\s+-[a-z]+)*\s*<<", line)
        while i < len(lines):
            body = lines[i]
            i += 1
            if (body.strip() if dash else body) == tag:
                break
            if feeds_shell:
                out.append(body)
    return "\n".join(out)

REDIRECT = re.compile(r"&>>?|<<<|<<-?|<>|>>|>&|<&|>\||<|>")
REDIRECT_TARGETS = []  # files read or written by redirects (> file, < file), checked in scan()

def simple_commands(text):
    """Split text into simple commands (lists of words) the way bash reads it."""
    return [c[0] for c in parse_commands(text)]

def parse_commands(text):
    """Split text into simple commands the way bash reads it.

    Quoted text stays one word even across newlines, a backslash-newline joins
    lines, and only unquoted newlines and ; & | ( ) end a command. Redirections
    and their targets (2>&1, > file, <<EOF) are dropped. Raises ValueError on
    an unclosed quote. Returns (words, depth, before, after): depth counts the
    open ( and $( around the command, before and after are the operators next
    to it (";", "&&", "||", "|", "&", "(", ")", "\\n" or "").
    """
    cmds, words, cur, skip, i, n = [], [], None, False, 0, len(text)
    depth, last_op = 0, ""

    def flush():
        nonlocal cur, skip
        if cur is not None:
            if skip:
                REDIRECT_TARGETS.append(cur)
                skip = False
            else:
                words.append(cur)
        cur = None

    def end_command(op=""):
        nonlocal words, skip, last_op
        flush()
        if words:
            cmds.append((words, depth, last_op, op))
        last_op = op
        words, skip = [], False

    while i < n:
        c = text[i]
        if c == "\\":
            if text[i + 1:i + 2] != "\n":
                cur = (cur or "") + text[i + 1:i + 2]
            i += 2
        elif c == "$" and text[i + 1:i + 2] == "\"":
            i += 1  # $"..." (locale quoting) reads like "..."
        elif c == "$" and text[i + 1:i + 2] == "\x27":
            # $ followed by a single-quoted string (ANSI-C quoting): decode the
            # escapes the way bash does.
            buf, i = "", i + 2
            while True:
                if i >= n:
                    raise ValueError("unclosed $\x27 quote")
                d = text[i]
                if d == "\x27":
                    i += 1
                    break
                if d == "\\" and i + 1 < n:
                    e = text[i + 1]
                    m = re.match(r"x([0-9A-Fa-f]{1,2})|([0-7]{1,3})", text[i + 1:i + 4])
                    if m:
                        buf += chr(int(m.group(1), 16) if m.group(1) else int(m.group(2), 8))
                        i += 1 + len(m.group(0))
                        continue
                    buf += {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "e": "\x1b",
                            "f": "\f", "v": "\v"}.get(e, e)
                    i += 2
                    continue
                buf += d
                i += 1
            cur = (cur or "") + buf
        elif c == "\x27":
            j = text.find("\x27", i + 1)
            if j < 0:
                raise ValueError("unclosed single quote")
            cur = (cur or "") + text[i + 1:j]
            i = j + 1
        elif c == "\"":
            buf, i = "", i + 1
            while True:
                if i >= n:
                    raise ValueError("unclosed double quote")
                d = text[i]
                if d == "\"":
                    i += 1
                    break
                if d == "\\" and text[i + 1:i + 2] in ("$", "`", "\"", "\\", "\n"):
                    if text[i + 1] != "\n":
                        buf += text[i + 1]
                    i += 2
                    continue
                buf += d
                i += 1
            cur = (cur or "") + buf
        elif c == "#" and cur is None:
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c in " \t\r":
            flush()
            i += 1
        elif c in "<>" or text.startswith("&>", i):
            if c in "<>" and cur is not None and cur.isdigit():
                cur = None  # file descriptor, as in 2>&1
            flush()
            if c in "<>" and text[i + 1:i + 2] == "(":
                end_command("(")  # process substitution: its body is a command
                depth += 1
                i += 2
                continue
            i = REDIRECT.match(text, i).end()
            skip = True  # the next word is the redirect target, not an argument
        elif c in "\n;&|()":
            op = text[i:i + 2] if text[i:i + 2] in ("&&", "||") else c
            end_command(op)
            if c == "(":
                depth += 1
            elif c == ")":
                depth = max(0, depth - 1)
            i += len(op)
        else:
            cur = (cur or "") + c
            i += 1
    end_command()
    return cmds

ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=")

def unwrap(argv):
    return unwrap_full(argv)[0]

def unwrap_full(argv):
    """Drop env assignments and wrappers in front of a command.

    Returns (argv, names, moved): the names of the environment variables the
    prefix sets (VAR=x, env VAR=x, env -S "VAR=x ..."), and whether it moves
    the command to another folder or cannot be read (env -C, an unknown env
    option).
    """
    names, moved = set(), False
    while argv:
        a = argv[0]
        m = ASSIGNMENT.match(a)
        if m:
            names.add(m.group(1))
            argv = argv[1:]
        elif a in KEYWORDS:
            argv = argv[1:]
        elif os.path.basename(a) == "env":
            argv = argv[1:]
            while argv and argv[0].startswith("-") and argv[0] != "--":
                x = argv[0]
                if x in ("-i", "--ignore-environment", "-0", "--null", "-"):
                    argv = argv[1:]
                elif x in ("-u", "--unset"):
                    argv = argv[2:]
                elif x.startswith("--unset=") or (x.startswith("-u") and len(x) > 2):
                    argv = argv[1:]
                elif x in ("-S", "--split-string"):
                    argv = (argv[1].split() if len(argv) > 1 else []) + argv[2:]
                    break
                elif x.startswith("--split-string="):
                    argv = x.split("=", 1)[1].split() + argv[1:]
                    break
                elif x.startswith("-S"):
                    argv = x[2:].split() + argv[1:]
                    break
                else:
                    moved = True  # -C/--chdir and anything unknown
                    argv = argv[2:] if x in ("-C", "--chdir") else argv[1:]
            if argv and argv[0] == "--":
                argv = argv[1:]
        elif os.path.basename(a) in WRAPPERS:
            argv = argv[1:]
            while argv and argv[0].startswith("-"):
                argv = argv[1:]
        elif a == "timeout":
            argv = argv[1:]
            while argv and (argv[0].startswith("-") or re.match(r"^[0-9.]+[smhd]?$", argv[0])):
                argv = argv[1:]
        elif a in ("xargs",):
            argv = argv[1:]
            while argv and argv[0].startswith("-"):
                argv = argv[1:]
        else:
            break
    return argv, names, moved

def current_branch(path):
    try:
        r = subprocess.run(["git", "-C", path, "symbolic-ref", "--short", "-q", "HEAD"],
                           capture_output=True, text=True, timeout=3)
        return r.stdout.strip() or None
    except Exception:
        return None

# A release tag: v1, v1.2.3, v2.0.0-rc.1, refs/tags/v1.2.3 (optionally src:dst),
# not a branch such as v2-redesign.
RELEASE_TAG = re.compile(r"^\+?(refs/tags/)?v[0-9]+((\.[0-9]+)+([-+][0-9A-Za-z.-]+)?)?"
                         r"(:(refs/tags/)?v[0-9][^:]*)?$")
TAG_LIST_FLAGS = {"-l", "--list", "-v", "--verify", "--contains", "--no-contains",
                  "--points-at", "--merged", "--no-merged"}

def git_subcommand(args, here):
    """args after "git": skip global options; returns (subcommand, rest, git_dir)."""
    git_dir = here
    while args:
        if args[0] == "-C" and len(args) > 1:
            git_dir = os.path.join(git_dir, os.path.expanduser(args[1]))
            args = args[2:]
        elif args[0] == "-c":
            args = args[2:]
        elif args[0].startswith("-"):
            args = args[1:]
        else:
            return args[0], args[1:], git_dir
    return None, [], git_dir

def check_git(args, here):
    sub, rest, git_dir = git_subcommand(args, here)
    if sub == "tag":
        if any(flag_name(a) in TAG_LIST_FLAGS for a in rest):
            return None
        if any(RELEASE_TAG.match(a) for a in rest if not a.startswith("-")):
            return "creates or changes a release tag (v*), which publishes a release"
        return None
    if sub == "push":
        return check_push(rest, git_dir)
    return None

def check_push(rest, git_dir):
    if any(a in ("--tags", "--follow-tags", "--mirror") for a in rest):
        return "pushes tags, and a v* tag publishes a release"
    positional = [a for a in rest if not a.startswith("-")]
    if "tag" in positional[1:] or any(RELEASE_TAG.match(r) for r in positional[1:]):
        return "pushes a release tag (v*), which publishes a release"
    hard = any(a in ("-f", "--force") or (re.match(r"^-[a-zA-Z]*f[a-zA-Z]*$", a) and not a.startswith("--")) for a in rest)
    lease = any(a.startswith("--force-with-lease") or a.startswith("--force-if-includes") for a in rest)
    refspecs = positional[1:]
    plus = any(r.startswith("+") for r in refspecs)
    if hard or plus:
        return "force-pushes to a remote branch"
    if not lease:
        return None
    targets = []
    for r in refspecs:
        r = r.lstrip("+")
        dst = r.split(":", 1)[1] if ":" in r else r
        dst = re.sub(r"^refs/heads/", "", dst)
        if dst == "HEAD":
            dst = current_branch(git_dir) or ""
        targets.append(dst)
    if not targets:
        b = current_branch(git_dir)
        if b is None:
            return "force-pushes, and the branch could not be checked"
        targets = [b]
    if any(t in PROTECTED or t == "" for t in targets):
        return "force-pushes to main or master"
    return None

# pass-env run/pipe pass a secret without asking only to the known deploy and
# test tools below, run the way the project defines them (owner, 2026-11-09 and
# 2026-11-10). Anything that could run code the command line itself supplies
# asks: inline code (node -e, python -c, npx -c), a script outside the project,
# an interpreter reading stdin, a config outside the project, or an environment
# variable that injects code (NODE_OPTIONS, PATH, ...). Printing forms are also
# blocked by deny rules in settings.json.
# Owner, 2026-11-15: stored secrets may be used by tools, tests and scripts in
# his own projects without a prompt, as long as a secret never appears in the
# chat. So `run` also allows a few whole CLIs of his own accounts (narrowed
# below) and script files inside the current git project; `pipe` stays a short
# list of commands that store the value somewhere (SECRET_SINKS).
#
# How a use is judged (secret_use_reason): the command is fully unwrapped
# first (env assignments, env options, npx/pnpm exec/uv run launchers), every
# ordinary check runs on the unwrapped command, and only then the allow lists.
# Anything that changes where the command runs, which binary answers or which
# host it talks to is "not known safe" and asks: env assignments (beyond
# SAFE_ENV on run), env -C and --cwd style flags, a package a launcher would
# download under a name the vendor does not own, host and URL flags, @file and
# path arguments outside the project, and $() or backticks in the arguments.
SAFE_SECRET_USES = [
    ["wrangler", "deploy"], ["wrangler", "secret", "put"], ["wrangler", "secret", "bulk"],
    ["wrangler", "d1", "migrations"], ["wrangler", "deployments"], ["wrangler", "versions"],
    ["wrangler", "dev"], ["wrangler", "types"],
    ["opennextjs-cloudflare"], ["vercel", "env", "add"], ["vercel", "deploy"], ["vercel", "--prod"],
    ["next", "dev"], ["next", "build"], ["next", "start"],
    ["playwright", "test"], ["vitest"],
]
# run only: whole CLIs. wrangler_reason, the gh checks and dcg still run first;
# gh is narrowed to read commands (gh_read_ok) and turso loses `db shell`.
RUN_ONLY_USES = [
    ["wrangler"], ["gh"], ["turso"], ["sentry-cli"], ["stripe"], ["tsc"], ["tauri"],
    ["astro"], ["vite"], ["drizzle-kit", "generate"], ["drizzle-kit", "migrate"],
    ["prisma", "migrate", "deploy"], ["prisma", "generate"], ["bun", "test"],
]
# pipe only: commands that read the value on stdin and store it. docker login,
# gh secret set and pass-env set have their own checks (pipe_sink_ok).
SECRET_SINKS = [
    ["wrangler", "pages", "secret", "put"], ["wrangler", "pages", "secret", "bulk"],
    ["wrangler", "secrets-store", "secret", "create"],
    ["flyctl", "secrets", "import"], ["fly", "secrets", "import"],
    ["supabase", "secrets", "set"], ["convex", "env", "set"],
]
DOCKER_REGISTRIES = {"ghcr.io", "docker.io", "index.docker.io", "registry-1.docker.io"}
OWNER = "n8watkins"
# npm packages whose name is the vendor CLI itself, so npx/bunx/pnpm dlx may
# fetch them. Others (gh, tsc, turso, sentry-cli, tauri, opennextjs-cloudflare
# on npm belong to someone else or are not the CLI) run only from the project:
# bare, ./node_modules/.bin/<tool>, pnpm exec or npx --no-install.
VENDOR_PACKAGES = {"wrangler", "vitest", "playwright", "next", "vercel", "tsx", "prisma",
                   "drizzle-kit", "astro", "vite", "convex", "supabase"}
# Scoped packages that install one of the tools above (all vendor-owned).
SCOPED_TOOLS = {"@opennextjs/cloudflare": "opennextjs-cloudflare", "@playwright/test": "playwright",
                "@sentry/cli": "sentry-cli", "@tauri-apps/cli": "tauri"}
# Launcher flags that only change prompting or output (npx, pnpm exec/dlx, npm exec).
WRAPPER_FLAGS = {"-y", "--yes", "--no", "--no-install", "-q", "--quiet", "--silent"}
# Environment variables a `run` may set without asking (pipe: none).
SAFE_ENV = {"NODE_ENV", "CI", "FORCE_COLOR", "NO_COLOR", "TZ", "LANG", "LC_ALL", "TERM"}
# Flags of those tools that load code or config from a path. CONFIG_FLAGS may
# name a file inside the project; the rest always ask.
CODE_FLAGS = {"-r", "--root", "--dir", "--setupFiles", "--globalSetup",
              "--globalTeardown", "--require", "--import", "--loader", "--environment",
              "--pool", "--node-options", "--preload", "--configLoader"}
CONFIG_FLAGS = {"-c", "--config", "--env-file", "--dotenv"}
# Flags that point a tool at another host, folder or proxy.
HOST_FLAGS = {"--hostname", "--host", "--url", "--api-base", "--api-url", "--base-url",
              "--endpoint", "--server", "--proxy", "--forward-to", "--forward-connect-to",
              "--cwd", "--chdir", "--directory", "--prefix", "-C"}
# Interpreter flags allowed before a project script file.
NODE_SCRIPT_FLAGS = {"--no-warnings", "--enable-source-maps"}
PYTHON_SCRIPT_FLAGS = {"-I", "-u", "-B"}
# python -m: a module in the project, or one of these test and migration runners.
PYTHON_MODULES = {"pytest", "unittest", "alembic"}
# uv run <command>: named project commands only.
UV_COMMANDS = {"pytest", "alembic", "ruff", "mypy"}
# Builtin commands per package manager: a package.json script with one of these
# names never runs as `pnpm <name>` / `yarn <name>`, the builtin does.
PNPM_BUILTINS = {
    "add", "install", "i", "update", "up", "upgrade", "remove", "rm", "uninstall", "un", "link",
    "ln", "unlink", "import", "rebuild", "rb", "prune", "fetch", "install-test", "it", "patch",
    "patch-commit", "patch-remove", "audit", "list", "ls", "ll", "la", "outdated", "why",
    "licenses", "exec", "run", "dlx", "create", "init", "publish", "pack", "deploy", "root",
    "bin", "store", "env", "setup", "server", "config", "c", "get", "set", "cat-file",
    "cat-index", "find-hash", "doctor", "self-update", "ignored-builds", "approve-builds",
    "dedupe", "recursive", "multi", "m", "help", "completion", "catalog", "access", "adduser",
    "bugs", "deprecate", "dist-tag", "docs", "edit", "info", "login", "logout", "owner", "ping",
    "prefix", "profile", "pkg", "repo", "s", "search", "set-script", "star", "stars", "team",
    "token", "unpublish", "unstar", "version", "view", "whoami", "xmas", "node", "x"}
YARN_BUILTINS = {
    "access", "add", "audit", "autoclean", "bin", "cache", "check", "config", "constraints",
    "create", "dedupe", "dlx", "exec", "explain", "generate-lock-entry", "global", "help",
    "import", "info", "init", "install", "licenses", "link", "list", "login", "logout", "node",
    "npm", "outdated", "owner", "pack", "patch", "patch-commit", "plugin", "policies", "publish",
    "rebuild", "remove", "run", "search", "set", "stage", "tag", "team", "unlink", "unplug", "up",
    "upgrade", "upgrade-interactive", "version", "versions", "why", "workspace", "workspaces"}
# Flags before a package.json script name (npm run, pnpm run); values are names.
SCRIPT_FLAGS = {"-s", "--silent", "--if-present", "-r", "--recursive", "--parallel", "--stream"}
SCRIPT_VALUE_FLAGS = {"-w", "--workspace", "--filter", "-F"}
# uv run flags: project options only (no --with, --script, -m, --python or --env-file).
UV_FLAGS = {"--frozen", "--locked", "--no-sync", "--all-extras", "--no-dev", "--offline", "-q", "--quiet"}
UV_VALUE_FLAGS = {"--extra", "--group", "--package"}
SCRIPT_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_:.-]*$")
# Environment variables that make a launcher load other code.
RISKY_ENV = re.compile(r"^(NODE_OPTIONS|NODE_PATH|PATH|PYTHON[A-Z_]*|LD_[A-Z_]+|DYLD_[A-Z_]+|"
                       r"BASH_ENV|ENV|PERL5[A-Z_]*|RUBYOPT|RUBYLIB|npm_config_[a-z_]+|NPM_CONFIG_[A-Z_]+)=")
ASSIGNERS = {"export", "declare", "typeset", "readonly", "local"}
# Builtins that set variables in ways the hook does not follow, or run text it
# cannot read: after one of them the environment and folder are unknown.
OPAQUE_BUILTINS = {"read", "mapfile", "readarray", "eval", "source", "."}
# Variables set for the rest of the command line (export X=1; X=1 alone),
# whether some other builtin may have set any (ENV_UNKNOWN), and whether the
# hook lost track of the folder bash is in. All only grow.
SHELL_ENV = set()
ENV_UNKNOWN = [False]
CWD_UNKNOWN = [False]

def risky(names):
    return any(RISKY_ENV.match(n + "=") for n in names)

def shell_assignments(argv):
    """Names a command sets for the commands after it: export X=1, or X=1 alone.

    Sets ENV_UNKNOWN for read, mapfile, eval, source, ., printf -v, set -a,
    and export/declare of a name without a value (it exports whatever another
    builtin put there).
    """
    a, names, _ = unwrap_full(argv)
    if not a:
        return names
    prog, args = a[0], a[1:]
    if prog in OPAQUE_BUILTINS or (prog == "printf" and any(x.startswith("-v") for x in args)) \
            or (prog == "set" and any(x == "allexport" or re.match(r"^-[a-z]*a", x) for x in args)):
        ENV_UNKNOWN[0] = True
    if prog in ASSIGNERS:
        if any(not x.startswith("-") and not ASSIGNMENT.match(x) for x in args):
            ENV_UNKNOWN[0] = True
        return {m.group(1) for m in map(ASSIGNMENT.match, args) if m}
    return set()

def flag_name(a):
    return a.split("=", 1)[0]

def flag_parts(args, i):
    """(name, value) of the flag at args[i]: --f=v, --f v, -fv, -f v."""
    x = args[i]
    nxt = args[i + 1] if i + 1 < len(args) else ""
    if x.startswith("--"):
        return (x.split("=", 1)[0], x.split("=", 1)[1]) if "=" in x else (x, nxt)
    if re.match(r"^-[A-Za-z]", x) and len(x) > 2:
        return x[:2], x[2:].lstrip("=")
    return x, nxt

def script_run_ok(a):
    """a = args after `npm run` / `pnpm run`: flags, then a package.json script name."""
    while a and a[0].startswith("-"):
        f = flag_name(a[0])
        if f in SCRIPT_FLAGS and "=" not in a[0]:
            a = a[1:]
        elif f in SCRIPT_VALUE_FLAGS:
            a = a[1:] if "=" in a[0] else a[2:]
        else:
            return False
    return bool(a) and bool(SCRIPT_NAME.match(a[0]))

def no_extra_npm_flags(a):
    """npm reads flags before `--` itself (--node-options, --script-shell)."""
    for x in a:
        if x == "--":
            return True
        if x.startswith("-") and flag_name(x) not in SCRIPT_FLAGS:
            return False
    return True

def project_root(here):
    """The git repository or worktree bash is in, or None (unknown folder, no repo)."""
    if CWD_UNKNOWN[0] or not here:
        return None
    try:
        r = subprocess.run(["git", "-C", here, "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=3)
        return os.path.realpath(r.stdout.strip()) if r.stdout.strip() else None
    except Exception:
        return None

def project_path(path, here, must_exist=True, kind="file"):
    """True if path names something inside the git project at `here`.

    No `..` component, no stdin (-), not under node_modules or .git, and after
    resolving symlinks it must sit in the repository or worktree that contains
    `here`. With must_exist, it must be an existing file (kind "file") or file
    or folder (kind "any").
    """
    if not path or path.startswith("-") or ".." in re.split(r"[/\\]", path):
        return False
    root = project_root(here)
    if not root:
        return False
    full = os.path.realpath(os.path.join(here, os.path.expanduser(path)))
    if not full.startswith(root + os.sep) and not (kind == "any" and full == root):
        return False
    inner = os.path.relpath(full, root).split(os.sep)
    if "node_modules" in inner or ".git" in inner:
        return False
    if not must_exist:
        return True
    return os.path.isfile(full) if kind == "file" else os.path.exists(full)

def project_file(path, here):
    return project_path(path, here)

def package_scripts(here):
    if CWD_UNKNOWN[0] or not here:
        return set()
    try:
        with open(os.path.join(here, "package.json")) as f:
            scripts = json.load(f).get("scripts") or {}
        return set(scripts) if isinstance(scripts, dict) else set()
    except Exception:
        return set()

def script_shorthand_ok(pm, name, here):
    """pnpm <script>, yarn <script>: a script package.json defines, not a builtin."""
    builtins = PNPM_BUILTINS if pm == "pnpm" else YARN_BUILTINS
    return bool(SCRIPT_NAME.match(name)) and name not in builtins and name in package_scripts(here)

def script_file_ok(a, here):
    """node|tsx|python|python3 [safe flags] <project file> [args], python -m <module>."""
    prog = a[0]
    if prog in ("node", "nodejs", "tsx"):
        allowed = NODE_SCRIPT_FLAGS if prog != "tsx" else set()
    elif re.match(r"^python(3(\.[0-9]+)?)?$", prog):
        allowed = PYTHON_SCRIPT_FLAGS
    else:
        return False
    rest = a[1:]
    while rest and rest[0].startswith("-") and rest[0] in allowed:
        rest = rest[1:]
    if not rest:
        return False
    if allowed is PYTHON_SCRIPT_FLAGS and rest[0] == "-m" and len(rest) > 1:
        mod = rest[1]
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$", mod):
            return False
        if any(x.startswith("-p") for x in rest[2:]):
            return False  # pytest -p loads a plugin by name
        top = mod.split(".")[0]
        return top in PYTHON_MODULES or project_file(top + ".py", here) \
            or project_file(os.path.join(top, "__init__.py"), here) \
            or project_file(os.path.join(top, "__main__.py"), here)
    return project_file(rest[0], here)

# Launchers that run another command: (words, kind). "npx" runs the bin of the
# project first and fetches from npm otherwise; "download" may fetch from npm;
# "pypi" fetches from PyPI, where none of the tool names here belong to the vendor;
# "local" runs only what the project has.
LAUNCHERS = {("npx",): "npx", ("bunx",): "download", ("pnpx",): "download",
             ("pnpm", "dlx"): "download", ("npm", "exec"): "download", ("npm", "x"): "download",
             ("yarn", "dlx"): "download", ("bun", "x"): "download", ("uvx",): "pypi",
             ("uv", "tool", "run"): "pypi", ("pipx", "run"): "pypi",
             ("pnpm", "exec"): "local", ("yarn", "exec"): "local", ("uv", "run"): "local"}
LAUNCHER_VALUE_FLAGS = {"-p", "--package", "--with", "--python", "--env-file", "--directory",
                        "--project", "--extra", "--group", "--index", "--from"}
# Package-manager options that may come before exec/dlx (pnpm --filter app exec,
# npm --prefix app exec); the launcher is still read, but never counts as clean.
PM_GLOBAL_VALUE_FLAGS = {"--filter", "-F", "-C", "--dir", "--prefix", "-w", "--workspace"}

def strip_launcher(a):
    """(command, kind, clean, call) for a launcher, or (a, None, True, None).

    clean is False when the launcher has flags other than the harmless
    WRAPPER_FLAGS (uv run: UV_FLAGS) or package-manager options before it;
    call is the text of npx -c "...". npx with -y/--yes or -p is "download".
    """
    if not a:
        return a, None, True, None
    first, pre_clean, b = os.path.basename(a[0]), True, list(a)
    if first in ("pnpm", "npm", "yarn"):
        j = 1
        while j < len(b):
            if first == "yarn" and b[j] == "workspace" and j + 1 < len(b):
                j += 2
            elif b[j].startswith("-"):
                f, _ = flag_parts(b, j)
                j += 2 if f in PM_GLOBAL_VALUE_FLAGS and "=" not in b[j] and len(b[j]) == len(f) else 1
            else:
                break
        if j > 1:
            b, pre_clean = [b[0]] + b[j:], False
    for words, kind in LAUNCHERS.items():
        if (first,) + tuple(b[1:len(words)]) == words:
            rest, clean, call = b[len(words):], pre_clean, None
            while rest and rest[0].startswith("-"):
                f, value = flag_parts(rest, 0)
                if rest[0] in ("--no-install", "--no") and kind == "npx":
                    kind = "local"
                elif rest[0] in ("-y", "--yes") and kind == "npx":
                    kind = "download"
                elif rest[0] in WRAPPER_FLAGS or (words == ("uv", "run") and rest[0] in UV_FLAGS):
                    pass
                elif words == ("uv", "run") and f in UV_VALUE_FLAGS:
                    rest = rest[1:] if "=" in rest[0] else rest[2:]
                    continue
                elif f in ("-c", "--call"):
                    call, clean = value, False
                else:
                    clean = False
                    if kind == "npx":
                        kind = "download"  # npx -p and friends: fetch on purpose
                    if f in LAUNCHER_VALUE_FLAGS and "=" not in rest[0] and len(rest[0]) == len(f):
                        rest = rest[2:]
                        continue
                rest = rest[1:]
            return rest, kind, clean, call
    return a, None, True, None

def local_bin(tool, here):
    """True if node_modules/.bin/<tool> exists between `here` and the project root."""
    root = project_root(here)
    if not root or not re.match(r"^[A-Za-z0-9_.-]+$", tool):
        return False
    d = os.path.realpath(here)
    while d.startswith(root):
        if os.path.exists(os.path.join(d, "node_modules", ".bin", tool)):
            return True
        if d == root:
            break
        d = os.path.dirname(d)
    return False

def tool_of(a, kind, here):
    """Normalize the tool name: pinned versions, scoped packages, node_modules/.bin.

    Returns None when the tool is not one a launcher may fetch or run.
    """
    if kind == "pypi":
        return None  # uvx, uv tool run, pipx run: PyPI names are not the vendors here
    tool = re.sub(r"(?<=.)@[^/]*$", "", a[0])  # pinned version: wrangler@4.1.0
    if tool.startswith("@"):
        return SCOPED_TOOLS.get(tool)
    if "/" in tool:
        if not re.match(r"^(\./)?node_modules/\.bin/[^/]+$", tool) or kind:
            return None  # a script or a binary outside the project
        return os.path.basename(tool)
    if kind == "npx" and tool not in VENDOR_PACKAGES and not (tool == a[0] and local_bin(tool, here)):
        return None  # npx would fetch whatever npm package has that name
    if kind == "download" and tool not in VENDOR_PACKAGES:
        return None  # bunx/dlx/npx -y fetch whatever package has that name
    return tool

BRACE_WORD = re.compile(r"\{[^{}]*(,|\.\.)[^{}]*\}")  # brace expansion: {a,b}, {1..3}
LOOPBACK = {"127.0.0.1", "localhost", "::1", "[::1]"}

def path_ok(x, here, mode):
    """An argument that is a path outside the project (absolute, ~ or ..) is not."""
    if not (x.startswith(("/", "~")) or ".." in re.split(r"[/\\]", x)):
        return True
    if mode == "pipe" and x == "/dev/stdin":
        return True
    return project_path(x, here, must_exist=False, kind="any")

def args_ok(args, here, mode):
    """Checks on every argument after the tool name."""
    for i, x in enumerate(args):
        if "$" in x or "`" in x or BRACE_WORD.search(x):
            return False  # expanded by the shell: unknown text
        if x.startswith("@") or "=@" in x:
            return False  # @file uploads a file
        if x.startswith("-") and len(x) > 1:
            f, value = flag_parts(args, i)
            if f in HOST_FLAGS:
                return False
            if f == "--ip" and value not in LOOPBACK:
                return False  # wrangler dev --ip 0.0.0.0 serves the Worker to the network
            if f in CONFIG_FLAGS:
                if not (project_file(value, here) or (mode == "pipe" and value == "/dev/stdin")):
                    return False
            elif f in CODE_FLAGS:
                return False
            elif f == "--reporter" and ("/" in value or "." in value):
                return False  # built-in reporters (list, verbose) are fine; a path is code
            if "=" in x and not path_ok(x.split("=", 1)[1], here, mode):
                return False
        elif not path_ok(x, here, mode):
            return False
    return True

GH_READ = {"pr": {"view", "list", "status", "checks", "diff"}, "run": {"view", "list", "watch"},
           "repo": {"view"}, "issue": {"view", "list"}, "workflow": {"view", "list"},
           "release": {"view", "list"}}

def gh_read_ok(a):
    """gh under run: read commands and GET API calls only (no extensions, aliases, gists)."""
    if "--web" in a or "-w" in a:
        return False  # opens a browser on the desktop
    if a[1:2] == ["api"]:
        rest = a[2:]
        for i, x in enumerate(rest):
            f, value = flag_parts(rest, i)
            if f in ("-X", "--method") and value.upper() != "GET":
                return False
            if f in GH_API_FIELD_FLAGS or f in ("-H", "--header"):
                return False  # fields make it a POST; a header can override the method
            if "://" in x:
                return False  # a full URL sends the token to that host
        return True
    return len(a) >= 3 and a[2] in GH_READ.get(a[1], ())

def subcommand(a, n):
    """The first n positional words after the tool (flags and their = values skipped)."""
    return [x for x in a[1:] if not x.startswith("-")][:n]

# A command whose output goes straight into the store: `... | pass-env set <entry>`
# (set by scan() for the command it is checking). Minting forms need it.
PIPED_TO_STORE = [False]
TURSO_READ = {("db", "list"), ("db", "show"), ("db", "inspect"), ("db", "locations"),
              ("group", "list"), ("org", "list"), ("plan", "show"), ("auth", "whoami")}
TURSO_MINT = (["db", "tokens", "create"], ["group", "tokens", "create"], ["auth", "token"],
              ["auth", "api-tokens", "mint"])

def turso_ok(a):
    """turso: read and list commands; a token-minting one only when piped into the store."""
    if any(subcommand(a, len(m)) == m for m in TURSO_MINT):
        return PIPED_TO_STORE[0]
    return tuple(subcommand(a, 2)) in TURSO_READ

def stripe_ok(a):
    """stripe: GET requests, list and retrieve; no listen (prints a signing secret), no writes."""
    sub = subcommand(a, 2)
    return sub[:1] in (["get"], ["version"], ["status"]) or (len(sub) == 2 and sub[1] in ("list", "retrieve"))

def sentry_ok(a):
    """sentry-cli: info and list commands only; uploads and releases ask."""
    sub = subcommand(a, 2)
    return sub[:1] == ["info"] or a[1:2] == ["--version"] or (len(sub) == 2 and sub[1] in ("list", "info"))

def gh_repo_ok(args):
    """gh secret set: the current repository, or --repo n8watkins/<name>; no org or user scope."""
    for i, x in enumerate(args):
        f, value = flag_parts(args, i)
        if f in ("-R", "--repo"):
            parts = value.split("/")
            if len(parts) == 3 and parts[0].lower() != "github.com" or len(parts) not in (2, 3) \
                    or parts[-2].lower() != OWNER:
                return False
        elif f in ("-o", "--org", "-u", "--user"):
            return False
    return True

def docker_login_ok(a):
    """docker login [ghcr.io|docker.io] -u <user> --password-stdin, nothing else."""
    if a[1:2] != ["login"]:
        return False
    rest, registry, stdin, i = a[2:], None, False, 0
    while i < len(rest):
        x = rest[i]
        if x == "--password-stdin":
            stdin = True
        elif x in ("-u", "--username"):
            i += 1
        elif x.startswith("--username=") or (x.startswith("-u") and len(x) > 2):
            pass
        elif x.startswith("-") or registry is not None:
            return False
        else:
            registry = x
        i += 1
    return stdin and (registry is None or registry.lower() in DOCKER_REGISTRIES)

def entry_ok(e):
    return bool(e) and not e.startswith(("-", "/", "~")) and ".." not in e.split("/") \
        and re.match(r"^[A-Za-z0-9_./-]+$", e) is not None

CLI_READ_OK = {"gh": gh_read_ok, "turso": turso_ok, "stripe": stripe_ok, "sentry-cli": sentry_ok}

def run_use_ok(a, here):
    """pass-env run -- <a>: a known tool, project script or package.json script."""
    uv = len(a) >= 2 and os.path.basename(a[0]) == "uv" and a[1] == "run"
    a, kind, clean, _ = strip_launcher(a)
    if not clean or not a:
        return False
    if uv:
        # uv run <named project command | project file | python <project file>>.
        ok = a[0] in UV_COMMANDS or project_file(a[0], here) or script_file_ok(a, here)
        return ok and args_ok(a[1:], here, "run")
    tool = tool_of(a, kind, here)
    if not tool:
        return False
    a = [tool] + a[1:]
    if tool == "npm":
        if len(a) >= 2 and a[1] in ("run", "run-script"):
            ok = script_run_ok(a[2:]) and no_extra_npm_flags(a[2:])
        else:
            ok = len(a) >= 2 and a[1] in ("test", "t", "start", "ci") and no_extra_npm_flags(a[2:])
    elif tool == "pnpm":
        if len(a) >= 2 and a[1] == "run":
            ok = script_run_ok(a[2:])
        else:
            ok = len(a) >= 2 and (a[1] in ("test", "dev", "build", "start")
                                  or script_shorthand_ok("pnpm", a[1], here))
    elif tool == "yarn":
        ok = len(a) >= 2 and (script_run_ok(a[2:]) if a[1] == "run" else script_shorthand_ok("yarn", a[1], here))
    elif tool == "bun" and a[1:2] == ["run"]:
        # bun run <name> runs a script, a file or any package bin: only a
        # script package.json defines, or a file inside the project.
        rest = a[2:]
        ok = bool(rest) and ((bool(SCRIPT_NAME.match(rest[0])) and rest[0] in package_scripts(here))
                             or project_file(rest[0], here))
    elif script_file_ok(a, here):
        ok = True
    else:
        ok = any(a[:len(p)] == p for p in SAFE_SECRET_USES + RUN_ONLY_USES)
        if ok and tool in CLI_READ_OK:
            ok = CLI_READ_OK[tool](a)
        if ok and tool == "tsc":
            for i, x in enumerate(a[1:], 1):
                f, value = flag_parts(a, i)
                if f in ("-p", "--project") and not project_path(value, here, kind="any"):
                    ok = False
        if ok and tool == "next":
            # next dev <dir> would run another project; allow only port and host values.
            rest, i = a[2:], 0
            while i < len(rest):
                if rest[i] in ("-H", "--hostname") and rest[i + 1:i + 2] and rest[i + 1] not in LOOPBACK:
                    ok = False  # serves the app to the network
                    break
                if rest[i] in ("-p", "--port", "-H", "--hostname"):
                    i += 2
                elif rest[i].startswith("-"):
                    i += 1
                else:
                    ok = False
                    break
    return ok and args_ok(a[1:], here, "run")

def pipe_sink_ok(a, here):
    """pass-env pipe <entry> -- <a>: a command that stores the value in his accounts."""
    a, kind, clean, _ = strip_launcher(a)
    if not clean or not a:
        return False
    tool = tool_of(a, kind, here)
    if not tool:
        return False
    a = [tool] + a[1:]
    if tool == "gh":
        ok = kind is None and a[1:3] == ["secret", "set"] and gh_repo_ok(a[3:])
    elif tool in SECRET_TOOLS:
        ok = kind is None and len(a) == 3 and a[1] == "set" and entry_ok(a[2])
    elif tool == "docker":
        ok = kind is None and docker_login_ok(a)
    else:
        ok = any(a[:len(p)] == p for p in SAFE_SECRET_USES + SECRET_SINKS)
    return ok and args_ok(a[1:], here, "pipe")

# The secret tool under its old and new name (owner, 2026-11-10).
SECRET_TOOLS = {"pass-env", "hushkey"}
# The one reason auto mode may judge for itself (see the end of this script).
NOT_SAFE = "gives a secret to a command that is not on the safe list"
HELLO_HELPER = re.compile(r"(pass-env|hushkey)-hello(\.exe)?($|[\x27\" ])", re.I)
WINDOWS_LAUNCHERS = {"cmd.exe", "cmd", "powershell.exe", "powershell", "pwsh.exe", "pwsh",
                     "wsl.exe", "explorer.exe", "rundll32.exe", "conhost.exe", "start"}
# The backup token and machine key, the unit that runs restic with them, the
# setup script, and the Windows Hello blob and helper folder. Any running
# command that names one asks.
BACKUP_PATHS = re.compile(r"\.config/hushkey($|[/\x27\"])|\.config/systemd/user/hushkey-backup|"
                          r"\.local/bin/hushkey-backup|(^|/)hello\.blob($|[\x27\"])|"
                          r"AppData[/\\]+Local[/\\]+(pass-env|hushkey)($|[/\\\x27\"])", re.I)
# Commands whose arguments are text (messages, bodies): only their file flags count.
FILE_FLAGS = {"-F", "--file", "--body-file", "-t", "--template"}
SYSTEMCTL_READ_ONLY = {"status", "is-active", "is-enabled", "is-failed", "list-timers",
                       "list-units", "list-unit-files", "start"}
RELEASE_ENDPOINT = re.compile(r"(^|/)(pending_deployments|environments|rulesets)($|[/?])")
GH_API_FIELD_FLAGS = {"-f", "-F", "--field", "--raw-field", "--input"}

def text_command(argv):
    prog = os.path.basename(argv[0])
    if prog in ("echo", "printf", "true", ":"):
        return True
    if prog == "git":
        return git_subcommand(argv[1:], ".")[0] in ("commit", "notes")
    if prog == "gh" and len(argv) >= 3:
        return argv[1] in ("pr", "issue") and argv[2] in ("create", "edit", "comment", "review", "close")
    return False

def backup_path_reason(argv):
    args = argv
    if text_command(argv):
        args = [a for i, a in enumerate(argv[1:], 1)
                if argv[i - 1] in FILE_FLAGS or (flag_name(a) in FILE_FLAGS and "=" in a)
                or re.match(r"^-F.", a)]
    if any(BACKUP_PATHS.search(a) for a in args):
        return "touches the Hushkey backup files, unit or script, or the Windows Hello files"
    return None

def tool_name(a):
    return re.sub(r"(?<=.)@[^/]*$", "", os.path.basename(a))

# wrangler words that delete, roll back, purge, or change who can reach or how
# long Cloudflare keeps something (owner: deletes and exposure need his OK).
# For the second set, a following list/get only reads.
WRANGLER_DESTROY = {"delete": "deletes something in Cloudflare", "rollback": "rolls a Worker back",
                    "purge": "purges a queue or cache",
                    "restore": "restores an older copy over live data"}
WRANGLER_EXPOSE = {"lifecycle": "changes how long an R2 bucket keeps objects",
                   "dev-url": "changes the public dev URL of an R2 bucket",
                   "domain": "changes a custom domain", "domains": "changes a custom domain",
                   "lock": "changes the lock rules of an R2 bucket"}

def wrangler_reason(argv):
    """argv is unwrapped and launcher-free (check() recurses through npx and friends)."""
    if not argv or tool_name(argv[0]) != "wrangler":
        return None
    pos = [x for x in argv[1:] if not x.startswith("-")]
    for i, w in enumerate(pos):
        if w in WRANGLER_DESTROY:
            return WRANGLER_DESTROY[w]
        if w in WRANGLER_EXPOSE and pos[i + 1:i + 2] not in (["list"], ["get"]):
            return WRANGLER_EXPOSE[w]
    return None

def release_reason(argv):
    """Publishing a package or running a release script (they tag and publish)."""
    prog, a = tool_name(argv[0]), argv[1:]
    if prog in ("npx", "bunx"):
        a = [x for x in a if not x.startswith("-")]
        if not a:
            return None
        prog, a = tool_name(a[0]), a[1:]
    pos = [x for x in a if not x.startswith("-")]
    if prog in ("npm", "pnpm", "yarn", "bun") and (pos[:1] == ["publish"] or pos[:2] == ["npm", "publish"]):
        return "publishes a package"
    if prog in ("npm", "pnpm", "yarn", "bun") and (pos[:2] in (["run", "release"], ["run-script", "release"])
                                                  or pos[:1] == ["release"]):
        return "runs the release script, which tags and publishes a release"
    if prog == "release-kit" and pos[:1] == ["release"]:
        return "runs the release script, which tags and publishes a release"
    if prog in ("node", "bun") and any(re.search(r"release-kit/release\.m?js$", x) for x in a):
        return "runs the release script, which tags and publishes a release"
    return None

def secret_use_reason(raw, argv, here):
    """pass-env|hushkey run|pipe: why it needs the owner, or None.

    raw is the command as written (with any env prefix), argv the unwrapped one.
    """
    sep = argv.index("--") if "--" in argv else len(argv)
    if "--no-mask" in argv[:sep]:
        return "turns off output masking for a secret"
    inner_raw = argv[sep + 1:]
    _, outer_names, outer_moved = unwrap_full(raw)
    inner, inner_names, inner_moved = unwrap_full(inner_raw)
    names = outer_names | inner_names | SHELL_ENV
    gh_sink = argv[1] == "pipe" and len(inner) >= 3 and inner[0] == "gh" and inner[1:3] == ["secret", "set"]
    inner_reason = None if gh_sink else check(inner_raw, here)
    if inner_reason and inner_reason != NOT_SAFE:
        return inner_reason
    if risky(names):
        return "gives a secret to a command with an environment variable that can load other code"
    if outer_moved or inner_moved or ENV_UNKNOWN[0]:
        return NOT_SAFE  # env -C, an env option the hook does not read, or read/eval/source
    if names - (SAFE_ENV if argv[1] == "run" else set()):
        return NOT_SAFE  # could point the tool at another host (CLOUDFLARE_API_BASE_URL, ...)
    ok = pipe_sink_ok(inner, here) if argv[1] == "pipe" else run_use_ok(inner, here)
    return None if ok and not inner_reason else NOT_SAFE

# Programs whose word, found anywhere in a command the hook does not know
# (mise exec, nice -n 5, sudo -u x, volta run, pnpm --filter x exec, ...), is
# checked again from that word on, so a wrapper never hides a specific reason.
NET_PROGS = {"gh", "git", "wrangler", "restic", "npm", "pnpm", "yarn", "bun", "npx", "bunx",
             "pnpx", "release-kit", "eval", "pass-env", "hushkey"} | SHELLS
UNREADABLE = "runs a command whose name is only known when the shell runs it ($VAR, $(...))"

def expand_braces(argv):
    """Bash brace expansion of {a,b} words (one level), empty results dropped."""
    out = []
    for w in argv:
        m = re.search(r"\{([^{}]*,[^{}]*)\}", w)
        if not m:
            out.append(w)
            continue
        for alt in m.group(1).split(","):
            word = w[:m.start()] + alt + w[m.end():]
            if word:
                out.extend(expand_braces([word]))
    return out

def check(argv, here):
    """Why the command needs the owner, or None.

    Every simple command goes through here. Positive allow decisions are made
    only in secret_use_reason (pass-env run/pipe); everything else is a list
    of specific reasons. To keep wrappers from hiding those reasons, a command
    whose program check_known() has no reason for is checked again from every
    later word naming one of NET_PROGS, and a program name the shell builds at
    run time asks.
    """
    a = expand_braces(unwrap(argv))
    if not a:
        return None
    if "$" in a[0] or "`" in a[0]:
        return UNREADABLE
    reason = check_known(argv, a, here)
    if reason or text_command(a) or os.path.basename(a[0]) in ("gh", "git", "wrangler") \
            or os.path.basename(a[0]) in SECRET_TOOLS:
        return reason
    soft = None
    for j in range(1, len(a)):
        name = tool_name(a[j].rsplit("#", 1)[-1])  # nix run nixpkgs#gh -- ...
        if name in NET_PROGS:
            rest = a[j + 1:]
            reason = check([name] + (rest[1:] if rest[:1] == ["--"] else rest), here)
            if reason == NOT_SAFE:
                soft = reason  # nice pass-env run -- ...: the secret use is not known safe
            elif reason:
                return reason
    return soft

def check_known(raw, argv, here):
    prog = os.path.basename(argv[0])
    if prog == "eval":
        return scan(" ".join(argv[1:]), here)
    if prog in SHELLS:
        for i, a in enumerate(argv[1:], 1):
            if re.match(r"^-[a-z]*c[a-z]*$", a) and i + 1 < len(argv):
                return scan(argv[i + 1], here)
        return None
    reason = backup_path_reason(argv)
    if reason:
        return reason
    if prog == "restic":
        return "runs restic, which reads the backup keys"
    if prog == "find" and any("hushkey" in a for a in argv) \
            and any(a in ("-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fls") for a in argv):
        return "runs a command on files named after Hushkey"
    if HELLO_HELPER.match(prog) or (prog.lower() in WINDOWS_LAUNCHERS
                                    and any(HELLO_HELPER.search(a) for a in argv[1:])):
        return "runs the Windows Hello helper directly"
    if prog == "systemctl":
        if "show-environment" in argv:
            return "prints the user service environment"
        if any("hushkey-backup" in a for a in argv):
            sub = [a for a in argv[1:] if not a.startswith("-")]
            if not sub or sub[0] not in SYSTEMCTL_READ_ONLY:
                return "reads or changes the Hushkey backup unit"
    if prog == "journalctl" and any("hushkey-backup" in a for a in argv):
        return "reads the Hushkey backup logs"
    # npx gh ..., pnpm exec wrangler ..., uv run gh ...: check the command the
    # launcher runs exactly like a bare one.
    inner, kind, _, call = strip_launcher(argv)
    if kind:
        reason = (scan(call, here) if call else None) or (check(inner, here) if inner else None)
        if reason:
            return reason
    reason = wrangler_reason(argv) or release_reason(argv)
    if reason:
        return reason
    if prog in SECRET_TOOLS and len(argv) > 1:
        if argv[1] == "unlock" and "--hello" in argv:
            return "starts a Windows Hello unlock"
        if argv[1] == "hello" and argv[2:3] and argv[2] in ("install", "enrol", "enroll", "forget"):
            return "changes the Windows Hello set-up"
    if prog in SECRET_TOOLS and len(argv) > 1 and argv[1] in ("run", "pipe"):
        return secret_use_reason(raw, argv, here)
    if prog in SECRET_TOOLS and len(argv) > 2 and argv[1] == "generate" \
            and any(x == "-c" or x.startswith("--copy") for x in argv[2:]):
        return "puts a new secret on the clipboard"
    if prog == "gh" and len(argv) >= 3:
        sub = argv[1:3]
        if sub[0] == "release" and sub[1] in ("create", "edit", "delete", "upload", "delete-asset"):
            return "creates or changes a GitHub release"
        if sub[0] == "repo" and sub[1] == "delete":
            return "deletes a GitHub repository"
        if sub[0] == "repo" and sub[1] == "archive":
            return "archives a GitHub repository"
        if sub[0] == "secret" and sub[1] in ("set", "delete", "remove"):
            return "changes a GitHub Actions secret"
        if sub[0] == "auth" and sub[1] == "refresh":
            return "changes what the GitHub login is allowed to do"
    if prog == "gh" and len(argv) >= 2 and argv[1] == "api":
        args = argv[2:]
        method = None
        for i, a in enumerate(args):
            if a in ("-X", "--method") and i + 1 < len(args):
                method = args[i + 1]
            elif a.startswith("-X") and len(a) > 2:
                method = a[2:]
            elif a.startswith("--method="):
                method = a.split("=", 1)[1]
        endpoints = [a for a in args if not a.startswith("-") and "/" in a]
        fields = any(flag_name(a) in GH_API_FIELD_FLAGS or re.match(r"^-[fF].", a) for a in args)
        if (method or ("POST" if fields else "GET")).upper() != "GET" \
                and any(RELEASE_ENDPOINT.search(e) for e in endpoints):
            return "approves a deployment or changes environments or rulesets through the GitHub API"
        if method and method.upper() == "DELETE":
            if endpoints and all(re.search(r"(^|/)repos/[^/]+/[^/]+/git/refs/heads/", e) for e in endpoints):
                return None
            return "sends a DELETE request to the GitHub API"
    if prog == "git":
        return check_git(argv[1:], here)
    return None

def scan(text, here):
    cmds = parse_commands(strip_heredocs(text))
    if any(BACKUP_PATHS.search(t) for t in REDIRECT_TARGETS):
        return "reads or writes the Hushkey backup files, unit or script through a redirect"
    # export NODE_OPTIONS=... or X=1 alone anywhere in the command line counts
    # for every command in it.
    for argv, _, _, _ in cmds:
        SHELL_ENV.update(shell_assignments(argv))
    # NOT_SAFE is the mildest reason (auto mode may drop it), so keep reading
    # the later commands for a stronger one.
    soft = None
    for k, (argv, depth, before, after) in enumerate(cmds):
        a = unwrap(argv)
        if a and a[0] in OPAQUE_BUILTINS:
            CWD_UNKNOWN[0] = True  # eval cd x, source x.sh: the folder may change
        if a and a[0] in ("cd", "pushd", "popd"):
            if len(a) > 1 and BACKUP_PATHS.search(a[1]):
                return "enters the Hushkey backup folder"
            target = a[1] if len(a) == 2 else ("~" if len(a) == 1 else None)
            literal = target is not None and target != "-" and not target.startswith("-") \
                and "$" not in target and "`" not in target
            path = os.path.join(here, os.path.expanduser(target)) if literal else None
            # The folder is followed only for a cd that surely ran and surely
            # moved bash: in the main shell (not ( ), $( ), a pipeline or the
            # background), not inside if/while/{ } (argv starts with a keyword),
            # and not next to && or || (it may not run, or may fail and the
            # line goes on), with one exception: a first command
            # `cd <existing dir> && ...`, where the rest runs only if it worked.
            sure = literal and a[0] != "popd" and depth == 0 and argv[0] not in KEYWORDS \
                and before not in ("|", "&", "&&", "||") and after not in ("|", "&", "||") \
                and (after != "&&" or (k == 0 and os.path.isdir(path)))
            if not sure:
                CWD_UNKNOWN[0] = True
            if path:
                here = path  # still the best guess for the git branch checks
            continue
        nxt = unwrap(cmds[k + 1][0]) if after == "|" and k + 1 < len(cmds) else []
        saved = PIPED_TO_STORE[0]
        PIPED_TO_STORE[0] = len(nxt) == 3 and os.path.basename(nxt[0]) in SECRET_TOOLS \
            and nxt[1] == "set" and entry_ok(nxt[2])
        try:
            reason = check(argv, here)
        finally:
            PIPED_TO_STORE[0] = saved
        if reason == NOT_SAFE:
            soft = reason
        elif reason:
            return reason
    return soft

def fallback(text):
    pats = [
        ("gh repo delete", "deletes a GitHub repository"),
        ("gh repo archive", "archives a GitHub repository"),
        ("gh secret set", "changes a GitHub Actions secret"),
        ("gh secret delete", "changes a GitHub Actions secret"),
        ("gh secret remove", "changes a GitHub Actions secret"),
        ("gh auth refresh", "changes what the GitHub login is allowed to do"),
    ]
    for p, r in pats:
        if p in text:
            return r
    if re.search(r"(pass-env|hushkey)\s+(run|pipe)\b", text):
        return "gives a secret to a command"
    if re.search(r"\.config/hushkey|hushkey-backup|\brestic\b|-hello\.exe|hello\.blob|--hello\b|"
                 r"\bhello\s+(install|enrol|enroll|forget)\b|show-environment", text):
        return "touches the Hushkey backup or Windows Hello"
    if re.search(r"gh\s+release\s+(create|edit|delete|upload)|\bpublish\b|\brun\s+release\b|"
                 r"git\s+push\b.*--(follow-)?tags|git\s+tag\b.*\sv[0-9]|r2\s+(bucket|object)\s", text):
        return "may publish a release or change an R2 bucket"
    if re.search(r"gh\s+api\b.*(-X\s*DELETE|--method[\s=]+DELETE)", text):
        return "sends a DELETE request to the GitHub API"
    if re.search(r"git\s+push\b.*(\s(-f|--force|--force-with-lease(=\S*)?)(\s|$)|\s\+\S+)", text):
        return "force-pushes to a remote branch"
    return None

try:
    reason = scan(cmd, cwd)
except ValueError:
    reason = fallback(cmd)  # an unclosed quote: bash would not run it either
except Exception as e:
    # A bug in this hook: still ask, and say so on stderr (the tests fail on it).
    sys.stderr.write(f"confirm-destructive-git: {type(e).__name__}: {e}\n")
    reason = fallback(cmd)

# Auto mode (owner, 2026-11-15): when the only reason is NOT_SAFE, stay silent
# so the auto mode classifier judges the call; an "ask" here would force a
# prompt and skip the classifier. Every other reason, and every other mode
# (bypassPermissions included), still asks.
if reason == NOT_SAFE and data.get("permission_mode") == "auto":
    reason = None

if reason:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": f"This command {reason}. Confirm before it runs.",
    }}))
' "$input"

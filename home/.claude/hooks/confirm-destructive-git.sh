#!/usr/bin/env bash
# User-level PreToolUse guard (every project): commands that delete or overwrite
# things on GitHub, or rewrite pushed history, always need the owner's OK.
# Emits an "ask" decision as JSON; silence = no opinion (normal rules apply).
#
# Asks for: gh repo delete/archive, gh secret set/delete/remove, gh auth refresh
# (changes the login's permissions), gh api DELETE calls, plain force pushes
# (-f/--force/+refspec), --force-with-lease pushes to main or master, and
# pass-env/hushkey run/pipe to anything but the known tools, project scripts and
# secret sinks (see SAFE_SECRET_USES: inline code, scripts or configs outside the
# project and interpreters reading stdin ask; in auto mode that one reason is
# left to the classifier), and pass-env/hushkey generate --copy.
# Hushkey (owner, 2026-11-10): run/pipe --no-mask, restic, the backup files,
# unit and script, Windows Hello unlock and helper runs, destructive wrangler r2
# commands, and releases (v* tags, gh release, publish, release scripts, gh api
# writes to pending_deployments, environments and rulesets).
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
    """Split text into simple commands (lists of words) the way bash reads it.

    Quoted text stays one word even across newlines, a backslash-newline joins
    lines, and only unquoted newlines and ; & | ( ) end a command. Redirections
    and their targets (2>&1, > file, <<EOF) are dropped. Raises ValueError on
    an unclosed quote.
    """
    cmds, words, cur, skip, i, n = [], [], None, False, 0, len(text)

    def flush():
        nonlocal cur, skip
        if cur is not None:
            if skip:
                REDIRECT_TARGETS.append(cur)
                skip = False
            else:
                words.append(cur)
        cur = None

    def end_command():
        nonlocal words, skip
        flush()
        if words:
            cmds.append(words)
        words, skip = [], False

    while i < n:
        c = text[i]
        if c == "\\":
            if text[i + 1:i + 2] != "\n":
                cur = (cur or "") + text[i + 1:i + 2]
            i += 2
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
                end_command()  # process substitution: its body is a command
                i += 1
                continue
            i = REDIRECT.match(text, i).end()
            skip = True  # the next word is the redirect target, not an argument
        elif c in "\n;&|()":
            end_command()
            i += 1
        else:
            cur = (cur or "") + c
            i += 1
    end_command()
    return cmds

def unwrap(argv):
    while argv:
        a = argv[0]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a):
            argv = argv[1:]
        elif a in KEYWORDS:
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
    return argv

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
# chat. So `run` also allows whole CLIs of his own accounts and script files
# inside the current git project (SCRIPT_RUNNERS below); `pipe` stays a short
# list of commands that store the value somewhere (SECRET_SINKS).
SAFE_SECRET_USES = [
    ["wrangler", "deploy"], ["wrangler", "secret", "put"], ["wrangler", "secret", "bulk"],
    ["wrangler", "d1", "migrations"], ["wrangler", "deployments"], ["wrangler", "versions"],
    ["wrangler", "dev"], ["wrangler", "types"],
    ["opennextjs-cloudflare"], ["vercel", "env", "add"], ["vercel", "deploy"], ["vercel", "--prod"],
    ["next", "dev"], ["next", "build"], ["next", "start"],
    ["playwright", "test"], ["vitest"],
]
# run only: whole CLIs. Destructive wrangler and gh subcommands are still caught
# by wrangler_reason/check() here and by dcg, which run before this list.
RUN_ONLY_USES = [
    ["wrangler"], ["gh"], ["turso"], ["sentry-cli"], ["stripe"], ["tsc"], ["tauri"],
    ["astro"], ["vite"], ["drizzle-kit", "generate"], ["drizzle-kit", "migrate"],
    ["prisma", "migrate", "deploy"], ["prisma", "generate"], ["bun", "test"],
]
# pipe only: commands that read the value on stdin and store it.
SECRET_SINKS = [
    ["wrangler", "pages", "secret", "put"], ["wrangler", "pages", "secret", "bulk"],
    ["wrangler", "secrets-store", "secret", "create"], ["docker", "login"],
    ["flyctl", "secrets", "import"], ["fly", "secrets", "import"],
    ["supabase", "secrets", "set"], ["convex", "env", "set"],
]
# Flags of those tools that load code or config from a path. -c/--config may
# name a file inside the project (CONFIG_FLAGS); the rest always ask.
CODE_FLAGS = {"-c", "--config", "-r", "--root", "--dir", "--setupFiles", "--globalSetup",
              "--globalTeardown", "--require", "--import", "--loader", "--environment",
              "--pool", "--node-options", "--preload"}
CONFIG_FLAGS = {"-c", "--config"}
# Interpreter flags allowed before a project script file.
NODE_SCRIPT_FLAGS = {"--no-warnings", "--enable-source-maps"}
PYTHON_SCRIPT_FLAGS = {"-I", "-u", "-B"}
# python -m: a module in the project, or one of these test and migration runners.
PYTHON_MODULES = {"pytest", "unittest", "alembic"}
# Package-manager commands that are never a package.json script shorthand.
PM_BUILTINS = {"exec", "dlx", "x", "create", "add", "install", "i", "remove", "rm", "update",
               "up", "upgrade", "link", "publish", "config", "env", "setup", "self-update",
               "patch", "node"}
# Scoped npx packages that install one of the tools above.
SCOPED_TOOLS = {"@opennextjs/cloudflare": "opennextjs-cloudflare", "@playwright/test": "playwright"}
# Wrapper flags that only change prompting or output (npx, pnpm exec/dlx, npm exec).
WRAPPER_FLAGS = {"-y", "--yes", "--no", "--no-install", "-q", "--quiet", "--silent"}
# Flags before a package.json script name (npm run, pnpm run); values are names.
SCRIPT_FLAGS = {"-s", "--silent", "--if-present", "-r", "--recursive", "--parallel", "--stream"}
SCRIPT_VALUE_FLAGS = {"-w", "--workspace", "--filter", "-F", "-C", "--dir"}
# uv run flags: project options only (no --with, --script, -m or --python).
UV_FLAGS = {"--frozen", "--locked", "--no-sync", "--all-extras", "--no-dev", "--offline", "-q", "--quiet"}
UV_VALUE_FLAGS = {"--extra", "--group", "--package", "--env-file"}
SCRIPT_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_:.-]*$")
INTERPRETER = re.compile(r"^(python[0-9.]*|pypy[0-9.]*|ipython|pip[0-9.]*|node|nodejs|bun|deno|"
                         r"perl|ruby|php|sh|bash|zsh|dash|env|xargs|uv|uvx|tsx|ts-node)$")
# Environment variables that make a launcher load other code.
RISKY_ENV = re.compile(r"^(NODE_OPTIONS|NODE_PATH|PATH|PYTHON[A-Z_]*|LD_[A-Z_]+|DYLD_[A-Z_]+|"
                       r"BASH_ENV|ENV|PERL5[A-Z_]*|RUBYOPT|RUBYLIB|npm_config_[a-z_]+|NPM_CONFIG_[A-Z_]+)=")
ASSIGNERS = {"env", "export", "declare", "typeset", "readonly", "local", "sudo"}
risky_env = False

def sets_risky_env(argv):
    """True if argv assigns a RISKY_ENV variable: VAR=x cmd, env VAR=x cmd, export VAR=x."""
    assigning = True
    for a in argv:
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a):
            if assigning and RISKY_ENV.match(a):
                return True
        elif os.path.basename(a) in ASSIGNERS:
            assigning = True
        elif not (assigning and a.startswith("-")):
            assigning = False
    return False

def flag_name(a):
    return a.split("=", 1)[0]

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
    try:
        r = subprocess.run(["git", "-C", here, "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=3)
        return r.stdout.strip() or None
    except Exception:
        return None

def project_file(path, here):
    """True if path names an existing file inside the git project at `here`.

    No `..` component, no stdin (-), and after resolving symlinks the file must
    sit in the repository or worktree that contains `here`.
    """
    if not path or path.startswith("-") or ".." in re.split(r"[/\\]", path):
        return False
    root = project_root(here)
    if not root:
        return False
    full = os.path.realpath(os.path.join(here, os.path.expanduser(path)))
    root = os.path.realpath(root)
    return full.startswith(root + os.sep) and os.path.isfile(full)

def package_scripts(here):
    try:
        with open(os.path.join(here, "package.json")) as f:
            scripts = json.load(f).get("scripts") or {}
        return set(scripts) if isinstance(scripts, dict) else set()
    except Exception:
        return set()

def script_shorthand_ok(name, here):
    """pnpm <script>, yarn <script>: a script package.json defines, not a builtin."""
    return bool(SCRIPT_NAME.match(name)) and name not in PM_BUILTINS and name in package_scripts(here)

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
        top = mod.split(".")[0]
        return top in PYTHON_MODULES or project_file(top + ".py", here) \
            or project_file(os.path.join(top, "__init__.py"), here) \
            or project_file(os.path.join(top, "__main__.py"), here)
    return project_file(rest[0], here)

def safe_secret_use(argv, mode="run", here="."):
    a = list(argv)
    # npx / bunx / pnpm exec / pnpm dlx / npm exec, with harmless flags only.
    while a and (os.path.basename(a[0]) in ("npx", "bunx") or a[:2] in (["pnpm", "exec"], ["pnpm", "dlx"], ["npm", "exec"])):
        a = a[2:] if a[0] in ("pnpm", "npm") else a[1:]
        while a and a[0].startswith("-"):
            if a[0] not in WRAPPER_FLAGS:
                return False
            a = a[1:]
    if not a:
        return False
    tool = re.sub(r"(?<=.)@[^/]*$", "", a[0])  # pinned version: wrangler@4.1.0
    if tool.startswith("@"):
        tool = SCOPED_TOOLS.get(tool)
        if not tool:
            return False
    elif "/" in tool:
        if not re.match(r"^(\./)?node_modules/\.bin/[^/]+$", tool):
            return False  # a script or a binary outside the project
        tool = os.path.basename(tool)
    a = [tool] + a[1:]
    run = mode == "run"
    if tool == "npm":
        if len(a) >= 2 and a[1] in ("run", "run-script"):
            return script_run_ok(a[2:]) and no_extra_npm_flags(a[2:])
        return len(a) >= 2 and a[1] in ("test", "t", "start", "ci") and no_extra_npm_flags(a[2:])
    if tool == "pnpm":
        if len(a) >= 2 and a[1] == "run":
            return script_run_ok(a[2:])
        if run and len(a) >= 2 and script_shorthand_ok(a[1], here):
            return True
        return len(a) >= 2 and a[1] in ("test", "dev", "build", "start")
    if run and tool == "yarn" and len(a) >= 2:
        if a[1] == "run":
            return script_run_ok(a[2:])
        return script_shorthand_ok(a[1], here)
    if run and tool == "bun" and a[1:2] == ["run"]:
        # bun run <name> runs a script, a file or any package bin: only a
        # script package.json defines, or a file inside the project.
        rest = a[2:]
        return bool(rest) and ((bool(SCRIPT_NAME.match(rest[0])) and rest[0] in package_scripts(here))
                               or project_file(rest[0], here))
    if run and script_file_ok(a, here):
        return True
    if tool == "uv":
        if a[1:2] != ["run"]:
            return False
        a = a[2:]
        while a and a[0].startswith("-"):
            f = flag_name(a[0])
            if f in UV_FLAGS and "=" not in a[0]:
                a = a[1:]
            elif f in UV_VALUE_FLAGS:
                a = a[1:] if "=" in a[0] else a[2:]
            else:
                return False
        if run and a and (project_file(a[0], here) or script_file_ok(a, here)):
            return True  # uv run <project file>, uv run python <project file>
        # A named project command (pytest, alembic), not an interpreter or a file.
        return bool(a) and bool(SCRIPT_NAME.match(a[0])) and not INTERPRETER.match(a[0]) \
            and not re.search(r"\.(py|pyw|sh)$", a[0])
    if mode == "pipe" and a[:1] == ["docker"] and "--password-stdin" not in a:
        return False
    if tool == "wrangler" and "delete" in [x for x in a[1:] if not x.startswith("-")][:4]:
        return False  # dcg misses some (wrangler secret delete): keep deletes off the list
    uses = SAFE_SECRET_USES + (RUN_ONLY_USES if run else SECRET_SINKS)
    if not any(a[:len(p)] == p for p in uses):
        return False
    for i, x in enumerate(a[1:], 1):
        f = flag_name(x)
        value = x.split("=", 1)[1] if "=" in x else (a[i + 1] if i + 1 < len(a) else "")
        if f == "--reporter":
            # Built-in reporters (list, html, verbose) are fine; a path is code.
            if "/" in value or "." in value:
                return False
        elif f in CONFIG_FLAGS and run and project_file(value, here):
            continue  # a config file inside the project
        elif f in CODE_FLAGS:
            return False
    if tool == "next":
        # next dev <dir> would run another project; allow only port and host values.
        rest, i = a[2:], 0
        while i < len(rest):
            if rest[i] in ("-p", "--port", "-H", "--hostname"):
                i += 2
            elif rest[i].startswith("-"):
                i += 1
            else:
                return False
    return True

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

def wrangler_reason(argv):
    for i, a in enumerate(argv[:4]):
        if tool_name(a) == "wrangler":
            pos = [x for x in argv[i + 1:] if not x.startswith("-")]
            if pos[:3] == ["r2", "bucket", "delete"]:
                return "deletes an R2 bucket"
            if pos[:3] == ["r2", "bucket", "lock"] and pos[3:4] != ["list"]:
                return "changes the lock rules of an R2 bucket"
            if pos[:3] == ["r2", "object", "delete"]:
                return "deletes an R2 object"
            return None
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

def check(argv, here):
    argv = unwrap(argv)
    if not argv:
        return None
    prog = os.path.basename(argv[0])
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
    reason = wrangler_reason(argv) or release_reason(argv)
    if reason:
        return reason
    if prog in SECRET_TOOLS and len(argv) > 1:
        if argv[1] == "unlock" and "--hello" in argv:
            return "starts a Windows Hello unlock"
        if argv[1] == "hello" and argv[2:3] and argv[2] in ("install", "enrol", "enroll", "forget"):
            return "changes the Windows Hello set-up"
    if prog in SECRET_TOOLS and len(argv) > 1 and argv[1] in ("run", "pipe"):
        inner = argv[argv.index("--") + 1:] if "--" in argv else []
        if "--no-mask" in (argv[:argv.index("--")] if "--" in argv else argv):
            return "turns off output masking for a secret"
        inner_u = unwrap(inner)
        piped_secret = argv[1] == "pipe" and (
            (len(inner_u) >= 3 and os.path.basename(inner_u[0]) == "gh" and inner_u[1:3] == ["secret", "set"])
            # pass-env set <entry>: a value a CLI minted goes straight into the store.
            or (len(inner_u) == 3 and os.path.basename(inner_u[0]) in SECRET_TOOLS
                and inner_u[1] == "set" and not inner_u[2].startswith("-")))
        if not piped_secret:
            reason = check(inner, here)
            if reason:
                return reason
        if risky_env or sets_risky_env(argv) or sets_risky_env(inner):
            return "gives a secret to a command with an environment variable that can load other code"
        if piped_secret or safe_secret_use(inner_u, argv[1], here):
            return None
        return NOT_SAFE
    if prog in SECRET_TOOLS and len(argv) > 2 and argv[1] == "generate" and "--copy" in argv[2:]:
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
    global risky_env
    cmds = simple_commands(strip_heredocs(text))
    if any(BACKUP_PATHS.search(t) for t in REDIRECT_TARGETS):
        return "reads or writes the Hushkey backup files, unit or script through a redirect"
    # export NODE_OPTIONS=... earlier in the same command line counts too.
    risky_env = risky_env or any(sets_risky_env(argv) for argv in cmds)
    # NOT_SAFE is the mildest reason (auto mode may drop it), so keep reading
    # the later commands for a stronger one.
    soft = None
    for argv in cmds:
        a = unwrap(argv)
        if a and a[0] in ("cd", "pushd"):
            if len(a) > 1 and BACKUP_PATHS.search(a[1]):
                return "enters the Hushkey backup folder"
            if len(a) > 1:
                here = os.path.join(here, os.path.expanduser(a[1]))
            continue
        reason = check(argv, here)
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
except Exception:
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

#!/usr/bin/env bash
# User-level PreToolUse guard (every project): commands that delete or overwrite
# things on GitHub, or rewrite pushed history, always need the owner's OK.
# Emits an "ask" decision as JSON; silence = no opinion (normal rules apply).
#
# Asks for: gh repo delete/archive, gh secret set/delete/remove, gh auth refresh
# (changes the login's permissions), gh api DELETE calls, plain force pushes
# (-f/--force/+refspec), --force-with-lease pushes to main or master, and
# pass-env run/pipe to anything but the known deploy and test tools (see
# SAFE_SECRET_USES: inline code, script paths, interpreters and custom configs ask).
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

def check_push(args, here):
    git_dir = here
    # args are after "git"; handle git -C dir push ...
    while args and args[0] != "push":
        if args[0] == "-C" and len(args) > 1:
            git_dir = os.path.join(git_dir, os.path.expanduser(args[1]))
            args = args[2:]
        elif args[0].startswith("-c") or args[0].startswith("--"):
            args = args[2:] if args[0] == "-c" else args[1:]
        else:
            return None
    if not args:
        return None
    rest = args[1:]
    hard = any(a in ("-f", "--force") or (re.match(r"^-[a-zA-Z]*f[a-zA-Z]*$", a) and not a.startswith("--")) for a in rest)
    lease = any(a.startswith("--force-with-lease") or a.startswith("--force-if-includes") for a in rest)
    positional = [a for a in rest if not a.startswith("-")]
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
# asks: inline code (node -e, python -c, npx -c), a script path, an interpreter,
# a custom config, or an environment variable that injects code (NODE_OPTIONS,
# PATH, ...). Printing forms are also blocked by deny rules in settings.json.
SAFE_SECRET_USES = [
    ["wrangler", "deploy"], ["wrangler", "secret", "put"], ["wrangler", "secret", "bulk"],
    ["wrangler", "d1", "migrations"], ["wrangler", "deployments"], ["wrangler", "versions"],
    ["wrangler", "dev"], ["wrangler", "types"],
    ["opennextjs-cloudflare"], ["vercel", "env", "add"], ["vercel", "deploy"], ["vercel", "--prod"],
    ["next", "dev"], ["next", "build"], ["next", "start"],
    ["playwright", "test"], ["vitest"],
]
# Flags of those tools that load code or config from a path.
CODE_FLAGS = {"-c", "--config", "-r", "--root", "--dir", "--setupFiles", "--globalSetup",
              "--globalTeardown", "--require", "--import", "--loader", "--environment",
              "--pool", "--node-options"}
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

def safe_secret_use(argv):
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
    if tool == "npm":
        if len(a) >= 2 and a[1] in ("run", "run-script"):
            return script_run_ok(a[2:]) and no_extra_npm_flags(a[2:])
        return len(a) >= 2 and a[1] in ("test", "t", "start", "ci") and no_extra_npm_flags(a[2:])
    if tool == "pnpm":
        if len(a) >= 2 and a[1] == "run":
            return script_run_ok(a[2:])
        return len(a) >= 2 and a[1] in ("test", "dev", "build", "start")
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
        # A named project command (pytest, alembic), not an interpreter or a file.
        return bool(a) and bool(SCRIPT_NAME.match(a[0])) and not INTERPRETER.match(a[0]) \
            and not re.search(r"\.(py|pyw|sh)$", a[0])
    if not any(a[:len(p)] == p for p in SAFE_SECRET_USES):
        return False
    for i, x in enumerate(a[1:], 1):
        f = flag_name(x)
        if f == "--reporter":
            # Built-in reporters (list, html, verbose) are fine; a path is code.
            value = x.split("=", 1)[1] if "=" in x else (a[i + 1] if i + 1 < len(a) else "")
            if "/" in value or "." in value:
                return False
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
    if prog == "pass-env" and len(argv) > 1 and argv[1] in ("run", "pipe"):
        inner = argv[argv.index("--") + 1:] if "--" in argv else []
        inner_u = unwrap(inner)
        piped_secret = (argv[1] == "pipe" and len(inner_u) >= 3
                        and os.path.basename(inner_u[0]) == "gh" and inner_u[1:3] == ["secret", "set"])
        if not piped_secret:
            reason = check(inner, here)
            if reason:
                return reason
        if risky_env or sets_risky_env(argv) or sets_risky_env(inner):
            return "gives a secret to a command with an environment variable that can load other code"
        if piped_secret or safe_secret_use(inner_u):
            return None
        return "gives a secret to a command that is not on the safe list"
    if prog == "gh" and len(argv) >= 3:
        sub = argv[1:3]
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
        if method and method.upper() == "DELETE":
            endpoints = [a for a in args if not a.startswith("-") and "/" in a]
            if endpoints and all(re.search(r"(^|/)repos/[^/]+/[^/]+/git/refs/heads/", e) for e in endpoints):
                return None
            return "sends a DELETE request to the GitHub API"
    if prog == "git":
        return check_push(argv[1:], here)
    return None

def scan(text, here):
    global risky_env
    cmds = simple_commands(strip_heredocs(text))
    # export NODE_OPTIONS=... earlier in the same command line counts too.
    risky_env = risky_env or any(sets_risky_env(argv) for argv in cmds)
    for argv in cmds:
        a = unwrap(argv)
        if a and a[0] == "cd":
            if len(a) > 1:
                here = os.path.join(here, os.path.expanduser(a[1]))
            continue
        reason = check(argv, here)
        if reason:
            return reason
    return None

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
    if re.search(r"pass-env\s+(run|pipe)\b", text):
        return "gives a secret to a command"
    if re.search(r"gh\s+api\b.*(-X\s*DELETE|--method[\s=]+DELETE)", text):
        return "sends a DELETE request to the GitHub API"
    if re.search(r"git\s+push\b.*(\s(-f|--force|--force-with-lease(=\S*)?)(\s|$)|\s\+\S+)", text):
        return "force-pushes to a remote branch"
    return None

try:
    reason = scan(cmd, cwd)
except Exception:
    reason = fallback(cmd)

if reason:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": f"This command {reason}. Confirm before it runs.",
    }}))
' "$input"

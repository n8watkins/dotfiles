#!/usr/bin/env bash
# User-level PreToolUse guard (every project): commands that delete or overwrite
# things on GitHub, or rewrite pushed history, always need the owner's OK.
# Emits an "ask" decision as JSON; silence = no opinion (normal rules apply).
#
# Asks for: gh repo delete/archive, gh secret set/delete/remove, gh auth refresh
# (changes the login's permissions), gh api DELETE calls, plain force pushes
# (-f/--force/+refspec), --force-with-lease pushes to main or master, and
# pass-env run/pipe to anything outside SAFE_SECRET_USES.
#
# Does not ask for (owner, 2026-11-09):
# - text that only mentions those commands (commit messages, PR bodies, heredocs,
#   quoted strings, scripts): only commands that actually run are checked;
# - --force-with-lease to a feature branch (routine after a rebase);
# - deleting a branch through the API (gh api -X DELETE .../git/refs/heads/...),
#   same as `git push origin --delete` (owner, 2026-11-02).
#
# If the command cannot be parsed, it falls back to the old plain-text match,
# so a parse failure can only add a prompt, never remove one.
# Tests: home/.claude/hooks/confirm-destructive-git.test.sh
input=$(cat)
exec python3 -I -c '
import json, os, re, shlex, subprocess, sys

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

def simple_commands(text):
    tokens, cur = [], []
    # Newlines separate commands too: split per line first.
    for line in text.split("\n"):
        lx = shlex.shlex(line, posix=True, punctuation_chars=";&|()<>")
        lx.whitespace_split = True
        lx.commenters = "#"
        for tok in lx:
            if tok and set(tok) <= set(";&|()<>"):
                if cur:
                    tokens.append(cur)
                cur = []
            else:
                cur.append(tok)
        if cur:
            tokens.append(cur)
        cur = []
    return tokens

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

# pass-env run/pipe pass a secret without asking only to these (owner, 2026-11-09).
# Printing forms are blocked by deny rules in settings.json either way.
SAFE_SECRET_USES = [
    ["wrangler", "deploy"], ["wrangler", "secret", "put"], ["wrangler", "secret", "bulk"],
    ["wrangler", "d1", "migrations"], ["wrangler", "deployments"], ["wrangler", "versions"],
    ["wrangler", "dev"], ["wrangler", "types"],
    ["opennextjs-cloudflare"], ["vercel", "env", "add"], ["vercel", "deploy"], ["vercel", "--prod"],
    ["npm", "run"], ["npm", "test"], ["npm", "start"], ["npm", "ci"],
    ["pnpm", "run"], ["pnpm", "test"], ["pnpm", "dev"], ["pnpm", "build"], ["pnpm", "start"],
    ["next", "dev"], ["next", "build"], ["next", "start"],
    ["playwright", "test"], ["vitest"], ["uv", "run"],
]

def safe_secret_use(argv):
    a = list(argv)
    # npx / pnpm exec / pnpm dlx wrappers, with their flags and a pinned version.
    while a and (os.path.basename(a[0]) in ("npx", "bunx") or a[:2] in (["pnpm", "exec"], ["pnpm", "dlx"], ["npm", "exec"])):
        a = a[2:] if a[0] in ("pnpm", "npm") else a[1:]
        while a and a[0].startswith("-"):
            a = a[1:]
    if not a:
        return False
    a[0] = re.sub(r"@[^/]*$", "", os.path.basename(a[0]))
    return any(a[:len(p)] == p for p in SAFE_SECRET_USES)

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
    for argv in simple_commands(strip_heredocs(text)):
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

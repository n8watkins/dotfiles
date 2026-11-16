#!/usr/bin/env bash
# User-level PreToolUse guard for the Cloudflare MCP connector: the `execute`
# tool runs a JavaScript async arrow function that calls
# cloudflare.request({ method, path, query?, body? }) with write access to the
# whole account. Cloudflare has no "may edit, may not delete" permission, so
# this hook asks the owner before code that deletes or cannot be undone.
# Emits an "ask" decision as JSON; silence = no opinion (normal rules apply).
#
# Asks for:
# - any DELETE request: "DELETE", 'delete', `Delete`, in any case and quoting;
# - a method the hook cannot read as one of GET, POST, PUT, PATCH (a variable,
#   a concatenation, a ternary, a template with ${...}, a shorthand { method },
#   or any other literal);
# - the short list of non-DELETE calls in DESTRUCTIVE below (cache purge
#   everything, destructive D1 SQL, R2 lifecycle and lock rules, a Worker upload
#   whose migrations delete a Durable Object class, KV bulk delete, Registrar,
#   API tokens);
# - input it cannot parse (fails safe).
# Does not ask for: GET-only code, other POST/PUT/PATCH calls, and the word
# "delete" in comments, string bodies, object keys or path segments.
# Only the tool whose name ends in cloudflare-api__execute is checked (the
# plugin prefix may change); every other tool passes untouched.
#
# This reads the code, it does not run it: code that builds its request in a
# way that hides the method from a reader (eval, JSON.parse of a string,
# Reflect, a method stored on an object somewhere other than a `method` key or
# `.method =` assignment) gets past it. It is a guardrail, not a sandbox.
# Tests: home/.claude/hooks/confirm-cloudflare-delete.test.sh
input=$(cat)
exec python3 -I -c '
import json, re, sys

# Non-DELETE calls that destroy data or cannot be undone. Each applies only when
# the code makes at least one request that is not a plain GET; the path pattern
# is matched against every string and template literal in the code except the
# paths of GET requests. (name, path regex, extra regex that must also appear
# in some literal or None, reason)
DESTRUCTIVE = [
    ("purge everything", r"/zones/[^/\s]+/purge_cache\b", r"purge_everything",
     "purges the whole cache of a zone"),
    ("D1 destructive SQL", r"/d1/database/[^/\s]+/(query|raw)\b", r"(?i)\b(drop|delete|truncate)\b",
     "runs DROP, DELETE or TRUNCATE on a D1 database"),
    ("R2 lifecycle or lock", r"/r2/buckets/[^/\s]+/(lifecycle|lock)\b", None,
     "changes the lifecycle (object expiry) or lock rules of an R2 bucket"),
    ("Durable Object class delete", r"/workers/scripts/[^/\s]+", r"deleted_classes",
     "uploads a Worker whose migrations delete a Durable Object class and all its data"),
    ("KV bulk delete", r"/storage/kv/namespaces/[^/\s]+/bulk/delete\b", None,
     "deletes KV keys in bulk"),
    ("Registrar", r"/registrar(/|\b)", None,
     "changes a domain registration (Registrar)"),
    ("API tokens", r"/tokens(?=/|\?|$)", None,
     "changes an API token"),
]
SAFE_METHODS = {"GET", "POST", "PUT", "PATCH"}
TOOL = re.compile(r"^mcp__.*cloudflare-api__execute$")

class Unreadable(Exception):
    pass

KEYWORDS = {"return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void",
            "throw", "instanceof", "yield", "await"}
PUNCT = ["...", "===", "!==", "**=", "<<=", ">>=", "=>", "==", "!=", "<=", ">=", "&&", "||",
         "??", "?.", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="]

def tokenize(src):
    """JavaScript tokens: (kind, value). Kinds: str (decoded), tpl (raw text,
    with ${...} kept), tplx (a template that has ${...}), id, num, punct, re.
    Comments are dropped. The code inside ${...} is tokenized too and added at
    the end. Raises Unreadable on an unclosed string, comment or template."""
    toks, inner, i, n = [], [], 0, len(src)

    def string_end(j, q):
        buf = ""
        while True:
            if j >= n or src[j] == "\n":
                raise Unreadable("unclosed string")
            d = src[j]
            if d == "\\":
                buf += src[j + 1:j + 2]
                j += 2
                continue
            if d == q:
                return buf, j + 1
            buf += d
            j += 1

    def template_end(j):
        """j is just past the opening backtick; returns (raw, has_interp, end)."""
        buf, interp = "", False
        while True:
            if j >= n:
                raise Unreadable("unclosed template")
            d = src[j]
            if d == "\\":
                buf += src[j:j + 2]
                j += 2
            elif d == "`":
                return buf, interp, j + 1
            elif src.startswith("${", j):
                k, depth = j + 2, 1
                while True:
                    if k >= n:
                        raise Unreadable("unclosed ${")
                    e = src[k]
                    if e in "\"\x27":
                        k = string_end(k + 1, e)[1]
                        continue
                    if e == "`":
                        k = template_end(k + 1)[2]
                        continue
                    if e == "{":
                        depth += 1
                    elif e == "}":
                        depth -= 1
                        if depth == 0:
                            break
                    k += 1
                inner.append(src[j + 2:k])
                buf += src[j:k + 1]
                interp, j = True, k + 1
            else:
                buf += d
                j += 1

    def regex_ok():
        if not toks:
            return True
        kind, val = toks[-1]
        if kind == "punct":
            return val not in (")", "]", "}")
        return kind == "id" and val in KEYWORDS

    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                raise Unreadable("unclosed comment")
            i = j + 2
        elif c in "\"\x27":
            val, i = string_end(i + 1, c)
            toks.append(("str", val))
        elif c == "`":
            val, interp, i = template_end(i + 1)
            toks.append(("tplx" if interp else "tpl", val))
        elif c == "/" and regex_ok():
            j, cls = i + 1, False
            while True:
                if j >= n or src[j] == "\n":
                    raise Unreadable("unclosed regular expression")
                d = src[j]
                if d == "\\":
                    j += 2
                    continue
                if d == "[":
                    cls = True
                elif d == "]":
                    cls = False
                elif d == "/" and not cls:
                    break
                j += 1
            j += 1
            while j < n and src[j].isalpha():
                j += 1
            toks.append(("re", src[i:j]))
            i = j
        elif c.isalpha() or c in "_$":
            m = re.compile(r"[\w$]+").match(src, i)
            toks.append(("id", m.group(0)))
            i = m.end()
        elif c.isdigit():
            m = re.compile(r"[\w.]+").match(src, i)
            toks.append(("num", m.group(0)))
            i = m.end()
        else:
            for p in PUNCT:
                if src.startswith(p, i):
                    break
            else:
                p = c
            toks.append(("punct", p))
            i += len(p)
    for code in inner:
        toks.append(("punct", ";"))
        toks.extend(tokenize(code))
    return toks

def literal(value_toks):
    """A value that is exactly one string, or a template without ${...}."""
    if len(value_toks) == 1 and value_toks[0][0] in ("str", "tpl"):
        return value_toks[0][1]
    return None

def path_text(value_toks):
    """A path as the owner would read it: a string or a template (${...} kept)."""
    if len(value_toks) == 1 and value_toks[0][0] in ("str", "tpl", "tplx"):
        return value_toks[0][1]
    return None

def objects(toks):
    """Each { ... } with its top-level keys: {key: value tokens or None (shorthand)}."""
    found, stack = [], []  # stack of (bracket, keys dict or None)
    for k, (kind, val) in enumerate(toks):
        if kind == "punct" and val in ("{", "(", "["):
            keys = {} if val == "{" else None
            stack.append((val, keys))
            if keys is not None:
                found.append(keys)
            continue
        if kind == "punct" and val in ("}", ")", "]"):
            if stack:
                stack.pop()
            continue
        if not stack or stack[-1][0] != "{" or kind not in ("id", "str", "tpl"):
            continue
        prev = toks[k - 1] if k else None
        if prev not in (("punct", "{"), ("punct", ",")):
            continue
        nxt = toks[k + 1] if k + 1 < len(toks) else ("punct", "}")
        keys = stack[-1][1]
        if nxt == ("punct", ":"):
            value, depth, j = [], 0, k + 2
            while j < len(toks):
                t = toks[j]
                if t[0] == "punct" and t[1] in ("{", "(", "["):
                    depth += 1
                elif t[0] == "punct" and t[1] in ("}", ")", "]"):
                    if depth == 0:
                        break
                    depth -= 1
                elif t == ("punct", ",") and depth == 0:
                    break
                value.append(t)
                j += 1
            keys.setdefault(val, value)
        elif kind == "id" and nxt in (("punct", ","), ("punct", "}")):
            keys.setdefault(val, None)  # shorthand { method }: a variable
    return found

def assignments(toks):
    """Values given by x.method = ... or x["method"] = ..., as token lists."""
    out = []
    for k in range(len(toks)):
        if toks[k] == ("id", "method") and k and toks[k - 1] in (("punct", "."), ("punct", "?.")):
            j = k + 1
        elif toks[k] == ("str", "method") and k and toks[k - 1] == ("punct", "[") \
                and toks[k + 1:k + 2] == [("punct", "]")]:
            j = k + 2
        else:
            continue
        if j >= len(toks) or toks[j][0] != "punct" or not toks[j][1].endswith("=") \
                or toks[j][1] in ("==", "===", "!=", "!==", "<=", ">="):
            continue  # a read (x.method === "GET"), not an assignment
        op, value, j = toks[j][1], [], j + 1
        while j < len(toks) and toks[j] not in (("punct", ";"), ("punct", "}"), ("punct", ")"), ("punct", ",")):
            value.append(toks[j])
            j += 1
        out.append(value if op == "=" else [("id", "?")])  # += and friends: not a literal
    return out

def method_of(value):
    """DELETE, a safe method, or None when it cannot be read as a literal."""
    if value is None:
        return None
    lit = literal(value)
    if lit is None:
        return None
    m = lit.strip().upper()
    return m if m in SAFE_METHODS or m == "DELETE" else None

def analyse(code):
    toks = tokenize(code)
    found = []        # what the reason lists, in order
    deletes, unread = [], 0
    any_write = False
    get_paths, write_paths = set(), set()
    for keys in objects(toks):
        has_method = "method" in keys
        path = path_text(keys["path"]) if keys.get("path") else None
        if not has_method:
            if "path" in keys and path is not None:
                get_paths.add(path)  # cloudflare.request defaults to GET
            continue
        m = method_of(keys["method"])
        if m == "GET":
            if path is not None:
                get_paths.add(path)
            continue
        any_write = True
        write_paths.add(path)
        if m == "DELETE":
            deletes.append(path)
        elif m is None:
            unread += 1
    get_paths -= write_paths  # a literal used by a write too is still scanned
    for value in assignments(toks):
        m = method_of(value)
        if m == "GET":
            continue
        any_write = True
        if m == "DELETE":
            deletes.append(None)
        elif m is None:
            unread += 1

    if deletes:
        named = sorted({p for p in deletes if p is not None})
        if named:
            found.append("sends DELETE to " + ", ".join(named[:5]) + (" and more" if len(named) > 5 else ""))
        if None in deletes:
            found.append("sends DELETE to a path the guard could not read")
    if unread:
        found.append("makes a request whose method could not be read")
    if any_write:
        literals = [v for kind, v in toks if kind in ("str", "tpl", "tplx")]
        scanned = [v for v in literals if v not in get_paths]
        words = literals + [v for kind, v in toks if kind == "id"]
        for _name, pat, extra, reason in DESTRUCTIVE:
            hits = sorted({v for v in scanned if re.search(pat, v)})
            if hits and (extra is None or any(re.search(extra, w) for w in words)):
                found.append(reason + " (" + ", ".join(hits[:3]) + ")")
    return found

def ask(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)

try:
    data = json.loads(sys.argv[1])
    if not isinstance(data, dict):
        raise ValueError("not an object")
except ValueError:
    ask("The guard could not read this Cloudflare tool call. Confirm before it runs.")

if not TOOL.match(str(data.get("tool_name") or "")):
    sys.exit(0)

tool_input = data.get("tool_input")
code = tool_input.get("code") if isinstance(tool_input, dict) else None
if not isinstance(code, str):
    ask("The guard could not find the code of this Cloudflare API call. Confirm before it runs.")

try:
    found = analyse(code)
except Unreadable as e:
    found = [f"has code the guard could not read ({e})"]
except Exception as e:
    # A bug in this hook: still ask, and say so on stderr (the tests fail on it).
    sys.stderr.write(f"confirm-cloudflare-delete: {type(e).__name__}: {e}\n")
    found = ["has code the guard could not read"]

if found:
    ask("This Cloudflare API call " + "; ".join(found) + ". Confirm before it runs.")
' "$input"

#!/usr/bin/env bash
# User-level PreToolUse guard for the Cloudflare MCP connector: the `execute`
# tool runs a JavaScript async arrow function that calls
# cloudflare.request({ method, path, query?, body? }) with write access to the
# whole account. Cloudflare has no "may edit, may not delete" permission, so
# this hook asks the owner before code that deletes or cannot be undone.
# Emits an "ask" decision as JSON; silence = no opinion (normal rules apply).
#
# Asks for:
# - any DELETE request: "DELETE", 'delete', `Delete`, escapes such as
#   "\u0044ELETE", in any case and quoting;
# - a method it cannot read as GET, POST, PUT or PATCH: a variable it cannot
#   resolve to one literal, a concatenation with a variable, a call, a getter,
#   a repeated `method` key, a shorthand { method }, or any other literal;
# - code that could set a method where the parser does not look (the backstop):
#   a string that is exactly DELETE outside a plain key value or comparison, a
#   JSON text with "method":"DELETE", a computed key on a request object, or
#   eval, Function, Reflect, defineProperty, fromEntries, fromCharCode or atob;
# - the calls in DESTRUCTIVE below that destroy data, cannot be undone or send
#   email, matched against the path of each request (concatenations and
#   templates read with * for the parts that are not literal);
# - input it cannot parse, and any failure of its own (fails closed).
# Does not ask for: GET-only code, other writes, and the word "delete" in
# comments, object keys, key values, comparisons, path segments, Worker source
# text, or bodies other than the SQL sent to D1.
# Only the tool whose name ends in cloudflare-api__execute is checked (the
# plugin prefix may change); every other tool passes untouched.
#
# This reads the code, it does not run it: a method computed from pieces the
# reader cannot see (a value fetched at run time, arithmetic on char codes
# without the names above) gets past it. It is a guardrail, not a sandbox.
# The payload is read from stdin inside Python: a large call (a Worker upload)
# can exceed the argument size limit of exec.
# Tests: home/.claude/hooks/confirm-cloudflare-delete.test.sh
exec python3 -I -c '
import json, re, sys

sys.setrecursionlimit(4000)

# Calls other than DELETE that destroy data, cannot be undone or send email.
# (methods, path regex, condition, reason). "write" means any method but GET.
# The condition is None, ("key", name): the body has that key and it is not
# false, ("sql",): the SQL sent (the body sql values), or ("code", regex):
# anywhere in the code. Paths are read with * for parts that are not literal.
END = r"(?=$|[?#*])"
DESTRUCTIVE = [
    ({"POST"}, r"/zones/[^/]+/purge_cache" + END, ("key", "purge_everything"),
     "purges the whole cache of a zone"),
    ("write", r"/d1/database/[^/]+/(query|raw)" + END, ("sql",),
     "runs DROP, DELETE, TRUNCATE or an UPDATE without WHERE on a D1 database"),
    ("write", r"/d1/database/[^/]+/time_travel/restore" + END, None,
     "restores a D1 database to an earlier point, replacing what it holds now"),
    ("write", r"/d1/database/[^/]+/import" + END, None,
     "imports SQL into a D1 database, which can drop or overwrite tables"),
    ("write", r"/r2/buckets/[^/]+/(lifecycle|lock)" + END, None,
     "changes the lifecycle (object expiry) or lock rules of an R2 bucket"),
    ("write", r"/workers/(dispatch/namespaces/[^/]+/)?scripts/", ("code", r"deleted_classes"),
     "uploads a Worker whose migrations delete a Durable Object class and all its data"),
    ("write", r"/storage/kv/namespaces/[^/]+/bulk/delete" + END, None,
     "deletes KV keys in bulk"),
    ("write", r"/zones/[^/]+/dns_records/batch" + END, ("key", "deletes"),
     "deletes DNS records in a batch"),
    ("write", r"/vectorize/v2/indexes/[^/]+/delete_by_ids" + END, None,
     "deletes vectors from a Vectorize index"),
    ("write", r"/queues/[^/]+/purge" + END, None,
     "purges every message in a queue"),
    ("write", r"/zones/[^/]+/email/routing/disable" + END, None,
     "turns off Email Routing for a zone"),
    ({"PATCH"}, r"/zones/[^/]+$", ("key", "paused"),
     "pauses Cloudflare on a zone"),
    ({"PUT"}, r"/rulesets/phases/[^/]+/entrypoint" + END, None,
     "replaces every rule in a ruleset phase"),
    ({"PUT"}, r"/rules/lists/[^/]+/items" + END, None,
     "replaces every item in a list"),
    ({"PUT"}, r"/access/apps/[^/]+$", ("key", "policies"),
     "replaces the policies of an Access application"),
    ("write", r"/challenges/widgets/[^/]+/rotate_secret" + END, None,
     "rotates the secret of a Turnstile widget"),
    ("write", r"/registrar(/|$)", None,
     "changes a domain registration (Registrar)"),
    ("write", r"/tokens(?=$|[/?#*])", None,
     "changes an API token"),
    # developers.cloudflare.com/email-service/api/send-emails/rest-api/ (send);
    # the SDK reference also lists send_raw.
    ("write", r"/email/sending/send(_raw)?" + END, None,
     "sends an email"),
]
DESTRUCTIVE_SQL = re.compile(r"(?i)\b(drop|delete|truncate)\b|\bupdate\b(?![\s\S]*\bwhere\b)")
SAFE_METHODS = {"GET", "POST", "PUT", "PATCH"}
RUNTIME_NAMES = ["eval", "Function", "Reflect", "defineProperty", "defineProperties",
                 "fromEntries", "fromCharCode", "atob"]
JSON_DELETE = re.compile(r"(?i)[\"\x27`]method[\"\x27`]\s*:\s*[\"\x27`]\s*delete")
TOOL = re.compile(r"^mcp__.*cloudflare-api__execute$")

class Unreadable(Exception):
    pass

KEYWORDS = {"return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void",
            "throw", "instanceof", "yield", "await"}
PUNCT = ["...", "===", "!==", "**=", "<<=", ">>=", "=>", "==", "!=", "<=", ">=", "&&", "||",
         "??", "?.", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="]
LITERAL = ("str", "tpl", "tplx")
ESC = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "v": "\v", "0": "\0"}
HEX = re.compile(r"x([0-9A-Fa-f]{2})|u([0-9A-Fa-f]{4})|u\{([0-9A-Fa-f]{1,6})\}")
IDENT = re.compile(r"(?:[\w$]|\\u[0-9A-Fa-f]{4}|\\u\{[0-9A-Fa-f]{1,6}\})+")
STRING_STOP = {q: re.compile("[\\\\\n" + q + "]") for q in "\"\x27"}
TEMPLATE_STOP = re.compile(r"[\\`$]")
IDENT_ESC = re.compile(r"\\u\{([0-9A-Fa-f]{1,6})\}|\\u([0-9A-Fa-f]{4})")

def code_point(h):
    v = int(h, 16)
    return chr(v) if v <= 0x10FFFF else ""

def unescape_at(src, j):
    """src[j] is a backslash: (decoded text, index after the escape)."""
    nxt = src[j + 1:j + 2]
    if nxt == "\n":
        return "", j + 2  # line continuation
    if nxt == "\r":
        return "", j + (3 if src[j + 2:j + 3] == "\n" else 2)
    m = HEX.match(src, j + 1)
    if m:
        return code_point(m.group(1) or m.group(2) or m.group(3)), m.end()
    return ESC.get(nxt, nxt), j + 2

def tokenize(src):
    """JavaScript tokens: (kind, value). Kinds: str (decoded), tpl (a template
    without ${...}, decoded), tplx (a template with ${...}, kept in its text),
    id (escapes decoded), num, punct, re. Comments are dropped. The code inside
    each ${...} is tokenized where it stands (one pass, however deep templates
    nest) and its tokens are added at the end. Raises Unreadable on an unclosed
    string, comment, template or ${...}."""
    n, tail = len(src), []

    def string_end(j, q):
        buf, stop = [], STRING_STOP[q]
        while True:
            m = stop.search(src, j)
            if not m or m.group(0) == "\n":
                raise Unreadable("unclosed string")
            k = m.start()
            buf.append(src[j:k])
            if src[k] == "\\":
                s, j = unescape_at(src, k)
                buf.append(s)
                continue
            return "".join(buf), k + 1

    def template_end(j):
        """j is just past the opening backtick: (text, has ${...}, end)."""
        buf, interp = [], False
        while True:
            m = TEMPLATE_STOP.search(src, j)
            if not m:
                raise Unreadable("unclosed template")
            buf.append(src[j:m.start()])
            j = m.start()
            d = src[j]
            if d == "\\":
                s, j = unescape_at(src, j)
                buf.append(s)
            elif d == "`":
                return "".join(buf), interp, j + 1
            elif src.startswith("${", j):
                sub, end = scan(j + 2, True)
                tail.append(("punct", ";"))
                tail.extend(sub)
                buf.append(src[j:end])
                interp, j = True, end
            else:
                buf.append(d)
                j += 1

    def scan(i, interp):
        """Tokens from i; inside a ${...} (interp), up to its closing brace.
        Returns (tokens, index after the end)."""
        toks, depth = [], 0

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
                val, has, i = template_end(i + 1)
                toks.append(("tplx" if has else "tpl", val))
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
            elif c.isalpha() or c in "_$" or (c == "\\" and IDENT.match(src, i)):
                m = IDENT.match(src, i)
                toks.append(("id", IDENT_ESC.sub(lambda g: code_point(g.group(1) or g.group(2)), m.group(0))))
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
                if p == "{":
                    depth += 1
                elif p == "}":
                    if interp and depth == 0:
                        return toks, i + 1  # the brace that closes this ${...}
                    depth -= 1
                toks.append(("punct", p))
                i += len(p)
        if interp:
            raise Unreadable("unclosed ${")
        return toks, i

    toks = scan(0, False)[0]
    return toks + tail

def P(v):
    return ("punct", v)

COMPARE = {P("==="), P("!=="), P("=="), P("!=")}
ASSIGN_OPS = {"=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "**=", "<<=", ">>=", "??=", "||=", "&&="}
OPERAND_END = ("id", "str", "tpl", "tplx", "num", "re")
INFIX_WORDS = {"as", "in", "of", "instanceof", "satisfies"}

class Code:
    """Tokens of one execute call and what the analysis reads from them."""

    def __init__(self, src):
        self.toks = t = tokenize(src)
        self.match, stack = {}, []
        for k, tok in enumerate(t):
            if tok[0] == "punct" and tok[1] in ("(", "[", "{"):
                stack.append(k)
            elif tok[0] == "punct" and tok[1] in (")", "]", "}"):
                if not stack or t[stack[-1]][1] != {")": "(", "]": "[", "}": "{"}[tok[1]]:
                    raise Unreadable("unbalanced brackets")
                self.match[stack.pop()] = k
        if stack:
            raise Unreadable("unbalanced brackets")
        self.opener = {c: o for o, c in self.match.items()}
        self.objects, self.by_start = [], {}
        self.key_values = set()     # literal tokens that are a key, or the value of a key other than method
        self.method_values = []     # value ranges assigned to a method outside an object literal
        self.computed_assign = False
        self.read_objects()
        self.read_assignments()
        self.read_bindings()

    def tok(self, k):
        return self.toks[k] if 0 <= k < len(self.toks) else ("eof", "")

    def value_end(self, j):
        """End of the expression that starts at j (exclusive)."""
        t, start = self.toks, j
        while j < len(t):
            kind, val = t[j]
            if kind == "punct":
                if val in ("(", "[", "{"):
                    j = self.match[j] + 1
                    continue
                if val in (",", "}", ")", "]", ";"):
                    break
            elif j > start and (kind in LITERAL or kind == "num" or (kind == "id" and val not in INFIX_WORDS)) \
                    and (t[j - 1][0] in OPERAND_END and t[j - 1][1] not in INFIX_WORDS
                         and not (t[j - 1][0] == "id" and t[j - 1][1] in KEYWORDS)
                         or t[j - 1] in (P(")"), P("]"), P("}"))):
                break  # two operands in a row: a statement ended without a semicolon
            j += 1
        return j

    def read_objects(self):
        t = self.toks
        for k, tok in enumerate(t):
            if tok != P("{"):
                continue
            obj = {"start": k, "end": self.match[k], "keys": {}, "computed": False}
            self.objects.append(obj)
            self.by_start[k] = obj
            j = k + 1
            while j < obj["end"]:
                j = self.read_member(obj, j)
                # skip to the next top-level comma
                while j < obj["end"] and t[j] != P(","):
                    j = self.match[j] + 1 if t[j][0] == "punct" and t[j][1] in ("(", "[", "{") else j + 1
                j += 1

    def set_key(self, obj, name, value):
        keys = obj["keys"]
        keys[name] = "repeated" if name in keys else value  # JavaScript keeps the last one

    def read_member(self, obj, j):
        """Reads the member that starts at j; returns where to keep scanning."""
        t = self.toks
        kind, val = t[j]
        if kind == "id" and val in ("get", "set", "async", "static") and t[j + 1][0] in ("id", "str") \
                and self.tok(j + 2) == P("("):
            if t[j + 1][1] == "method" and val in ("get", "set"):
                self.set_key(obj, "method", "getter")
            return j + 2
        if tok_is_key(t[j]):
            nxt = self.tok(j + 1)
            if nxt == P(":"):
                e = self.value_end(j + 2)
                self.set_key(obj, val, (j + 2, e))
                self.key_values.add(j)
                if val != "method" and e == j + 3 and t[j + 2][0] in LITERAL:
                    self.key_values.add(j + 2)
                return e
            if kind == "id" and nxt in (P(","), P("}"), P("=")):
                self.set_key(obj, val, None)  # shorthand { method }, or a default in a pattern
                return j + 1
            return j + 1
        if (kind, val) == ("punct", "["):
            close = self.match[j]
            inside = t[j + 1:close]
            after = self.tok(close + 1)
            if len(inside) == 1 and inside[0][0] in ("str", "tpl"):
                if after == P(":"):
                    e = self.value_end(close + 2)
                    self.set_key(obj, inside[0][1], (close + 2, e))
                    return e
                return close + 1
            obj["computed"] = True
            return close + 1
        return j + 1

    def read_assignments(self):
        """x.method = v, x["method"] = v, a class field method = v, and x[expr] = v."""
        t = self.toks
        for k, tok in enumerate(t):
            prev = self.tok(k - 1)
            if tok == ("id", "method") and prev in (P("."), P("?.")):
                op = k + 1
            elif tok == ("id", "method") and prev in (P("{"), P(";"), P("}")):
                op = k + 1  # a class field, or a statement that assigns a variable named method
            elif tok == P("[") and prev[0] in OPERAND_END + ("punct",) and prev not in (P("("), P(","), P("="), P(":"), P("{"), P(";")):
                close = self.match[k]
                nxt = self.tok(close + 1)
                if nxt[0] != "punct" or nxt[1] not in ASSIGN_OPS:
                    continue
                inside = t[k + 1:close]
                if len(inside) == 1 and inside[0][0] in ("str", "tpl"):
                    if inside[0][1] == "method":
                        self.method_values.append((close + 2, self.value_end(close + 2)) if nxt[1] == "=" else None)
                elif any(x == P("+") or x[0] == "tplx" for x in inside):
                    self.computed_assign = True  # o["meth" + "od"] = ...
                continue
            else:
                continue
            nxt = self.tok(op)
            if nxt[0] == "punct" and nxt[1] in ASSIGN_OPS:
                self.method_values.append((op + 1, self.value_end(op + 1)) if nxt[1] == "=" else None)

    def read_bindings(self):
        """const|let|var name = value, kept only for names assigned nowhere else."""
        t = self.toks
        decls, blocked = {}, set()
        for k, tok in enumerate(t):
            if tok[0] == "id" and tok[1] in ("const", "let", "var") and self.tok(k + 1)[0] == "id" \
                    and self.tok(k + 2) == P("="):
                decls.setdefault(t[k + 1][1], []).append((k + 3, self.value_end(k + 3)))
        for k, tok in enumerate(t):
            if tok[0] != "id":
                continue
            prev, nxt = self.tok(k - 1), self.tok(k + 1)
            declared = prev[0] == "id" and prev[1] in ("const", "let", "var") and nxt == P("=")
            if not declared and ((nxt[0] == "punct" and nxt[1] in ASSIGN_OPS | {"++", "--"})
                                 or prev in (P("++"), P("--")) or nxt == P("=>")):
                blocked.add(tok[1])
        for k, tok in enumerate(t):
            if tok == P("=>") and self.tok(k - 1) == P(")"):
                blocked.update(x[1] for x in t[self.opener[k - 1]:k - 1] if x[0] == "id")
            if tok == ("id", "function"):
                j = k + 1
                while self.tok(j)[0] == "id":
                    j += 1
                if self.tok(j) == P("("):
                    blocked.update(x[1] for x in t[j:self.match[j]] if x[0] == "id")
            if tok in (P("}"), P("]")) and self.tok(k + 1) == P("="):
                blocked.update(x[1] for x in t[self.opener[k]:k] if x[0] == "id")  # destructuring
            if tok[0] == "id" and tok[1] in ("of", "in") and self.tok(k - 1)[0] == "id":
                blocked.add(t[k - 1][1])  # for (const x of ...)
        self.bindings = {name: v[0] for name, v in decls.items() if len(v) == 1 and name not in blocked}

    # Reading values.

    def operand(self, j):
        """(text, end, is literal) for one operand of a + chain, or None."""
        t = self.tok(j)
        if t[0] in LITERAL or t[0] == "num":
            return t[1], j + 1, True
        if t == P("("):
            close = self.match[j]
            c = self.chain(j + 1)
            if c and c[1] == close and c[3]:
                return c[0], close + 1, c[2]
            return "*", close + 1, False
        if t[0] == "id" and t[1] not in KEYWORDS:
            j += 1
            while True:
                u = self.tok(j)
                if u in (P("."), P("?.")) and self.tok(j + 1)[0] == "id":
                    j += 2
                elif u[0] == "punct" and u[1] in ("[", "("):
                    j = self.match[j] + 1
                else:
                    return "*", j, False
        return None

    def chain(self, j):
        """A + chain from j: (text with * for the parts that are not literal,
        end, all literal, some literal)."""
        first = self.operand(j)
        if first is None:
            return None
        parts, j, pure, some = [first[0]], first[1], first[2], first[2]
        while self.tok(j) == P("+"):
            nxt = self.operand(j + 1)
            if nxt is None:
                break
            parts.append(nxt[0])
            pure, some = pure and nxt[2], some or nxt[2]
            j = nxt[1]
        return re.sub(r"\*+", "*", "".join(parts)), j, pure, some

    def strip_type(self, s, e):
        """Drops a TypeScript `as const` or `satisfies X` at the end."""
        if e - s >= 3 and self.toks[e - 2][0] == "id" and self.toks[e - 2][1] in ("as", "satisfies") \
                and self.toks[e - 1][0] == "id":
            return s, e - 2
        return s, e

    def resolve(self, s, e, depth=0):
        """A range that is one bound name, followed to its value."""
        if e == s + 1 and self.toks[s][0] == "id" and self.toks[s][1] in self.bindings and depth < 8:
            b = self.bindings[self.toks[s][1]]
            return self.resolve(b[0], b[1], depth + 1)
        return s, e

    def text(self, rng, pure=False):
        """The text of a value range (* for the unknown parts), or None when
        it is not one + chain or has no literal part at all."""
        if rng is None or rng in ("repeated", "getter"):
            return None
        s, e = self.resolve(*self.strip_type(*rng))
        c = self.chain(s) if s < e else None
        if not c or c[1] != e or not c[3] or (pure and not c[2]):
            return None
        return c[0]

    def shorthand(self, obj, name):
        """The range of a key, following a shorthand { name } to its binding."""
        v = obj["keys"].get(name)
        if v is None and name in obj["keys"]:
            return self.bindings.get(name)
        return v

    def methods(self, rng):
        """The set of methods a value can be, or None when it cannot be read."""
        if rng is None or rng in ("repeated", "getter"):
            return None
        s, e = self.resolve(*self.strip_type(*rng))
        q = self.find_top(s, e, P("?"))
        if q is not None:
            c = self.find_top(q + 1, e, P(":"))
            a = self.methods((q + 1, c)) if c is not None else None
            b = self.methods((c + 1, e)) if c is not None else None
            return a | b if a is not None and b is not None else None
        lit = self.text((s, e), pure=True)
        return None if lit is None else {lit.strip().upper()}

    def find_top(self, s, e, tok):
        j = s
        while j < e:
            u = self.toks[j]
            if u == tok:
                return j
            j = self.match[j] + 1 if u[0] == "punct" and u[1] in ("(", "[", "{") else j + 1
        return None

    def body_object(self, obj):
        rng = self.shorthand(obj, "body")
        if not isinstance(rng, tuple):
            return None
        s, e = self.resolve(*rng)
        if self.tok(s) == P("{") and self.match[s] == e - 1:
            return self.by_start[s]
        return None

    def inside(self, outer):
        return [o for o in self.objects if outer["start"] <= o["start"] <= outer["end"]]

def falsy(code, rng):
    if not isinstance(rng, tuple):
        return False
    s, e = rng
    return e == s + 1 and code.toks[s] in (("id", "false"), ("num", "0"), ("id", "null"), ("id", "undefined"))

def tok_is_key(tok):
    return tok[0] in ("id", "str", "tpl", "num")

def condition_met(code, cond, body):
    """Whether a DESTRUCTIVE condition holds, for a request with this body
    object (None when the body cannot be read: then the whole code counts)."""
    if cond is None:
        return True, None
    scope = code.inside(body) if body else code.objects
    if cond[0] == "key":
        if body:
            scope = [body]
        return any(cond[1] in o["keys"] and not falsy(code, o["keys"][cond[1]]) for o in scope), None
    if cond[0] == "code":
        return any(re.search(cond[1], v) for kind, v in code.toks if kind in LITERAL or kind == "id"), None
    sqls = [code.text(code.shorthand(o, "sql")) for o in scope if "sql" in o["keys"]]
    if not sqls or None in sqls:
        return True, "sends SQL to a D1 database that the guard could not read"
    return any(DESTRUCTIVE_SQL.search(s) for s in sqls), None

def row_applies(row_methods, m):
    if m is None:
        return True
    return bool(m - {"GET"}) if row_methods == "write" else bool(m & row_methods)

def analyse(src):
    code = Code(src)
    t = code.toks
    found, deletes, unread = [], [], 0
    requests = []  # (methods or None, path text or None, body object or None)
    for obj in code.objects:
        keys = obj["keys"]
        if "method" not in keys and "path" not in keys:
            continue
        m = code.methods(code.shorthand(obj, "method")) if "method" in keys else {"GET"}
        path = code.text(code.shorthand(obj, "path")) if "path" in keys else None
        requests.append((m, path, code.body_object(obj)))
    for rng in code.method_values:
        requests.append((code.methods(rng), None, None))

    for m, path, _ in requests:
        if m is not None and "DELETE" in m:
            deletes.append(path)
        elif m is None or m - SAFE_METHODS:
            unread += 1
    if deletes:
        named = sorted({p for p in deletes if p is not None})
        if named:
            found.append("sends DELETE to " + ", ".join(named[:5]) + (" and more" if len(named) > 5 else ""))
        if None in deletes:
            found.append("sends DELETE to a path the guard could not read")
    if unread:
        found.append("makes a request whose method could not be read")

    if not deletes and not unread:
        # Backstop: a method set where the parser does not look.
        for k, (kind, v) in enumerate(t):
            if kind in ("str", "tpl") and v.strip().upper() == "DELETE" and k not in code.key_values \
                    and code.tok(k - 1) not in COMPARE and code.tok(k + 1) not in COMPARE \
                    and code.tok(k - 1) != ("id", "case"):
                found.append("has the string DELETE outside a plain method key")
                break
        if any(kind in LITERAL and JSON_DELETE.search(v) for kind, v in t):
            found.append("has a JSON text that sends DELETE")
        if code.computed_assign or any(o["computed"] and ("path" in o["keys"] or "method" in o["keys"])
                                       for o in code.objects):
            found.append("sets a computed key on a request, which could be its method")
        names = [x for x in RUNTIME_NAMES if ("id", x) in t]
        if names:
            found.append("builds code or objects at run time (" + ", ".join(names) + ")")

    # The destructive table: each write with a readable path, and when some
    # write has no readable path, every + chain in the code.
    hits = []
    def check(m, path, body):
        for row_methods, pat, cond, reason in DESTRUCTIVE:
            if row_applies(row_methods, m) and re.search(pat, path):
                ok, extra = condition_met(code, cond, body)
                if extra:
                    hits.append(extra)
                elif ok:
                    hits.append(reason + " (" + path + ")")
    writes = [(m, p, b) for m, p, b in requests if m is not None and m - {"GET"}]
    for m, p, b in writes:
        if p is not None:
            check(m, p, b)
    if any(p is None for _, p, _ in writes):
        get_paths = {p for m, p, _ in requests if m == {"GET"}}
        for k in range(len(t)):
            if code.tok(k - 1) == P("+") or not (t[k][0] in LITERAL or t[k][0] == "id"):
                continue
            c = code.chain(k)
            if c and c[3] and c[0] not in get_paths:
                check(None, c[0], None)
    for h in hits:
        if h not in found:
            found.append(h)
    return found

def decide(raw):
    try:
        data = json.loads(raw)
    except ValueError:
        data = None
    if not isinstance(data, dict):
        return "The guard could not read this Cloudflare tool call. Confirm before it runs."
    if not TOOL.match(str(data.get("tool_name") or "")):
        return None
    tool_input = data.get("tool_input")
    src = tool_input.get("code") if isinstance(tool_input, dict) else None
    if not isinstance(src, str):
        return "The guard could not find the code of this Cloudflare API call. Confirm before it runs."
    try:
        found = analyse(src)
    except Unreadable as e:
        found = [f"has code the guard could not read ({e})"]
    except RecursionError:
        found = ["has code nested too deeply for the guard to read"]
    if found:
        return "This Cloudflare API call " + "; ".join(found) + ". Confirm before it runs."
    return None

try:
    reason = decide(sys.stdin.buffer.read())
except BaseException as e:
    # A bug in this hook: fail closed, and say so on stderr (the tests fail on it).
    sys.stderr.write(f"confirm-cloudflare-delete: {type(e).__name__}: {e}\n")
    reason = "The guard failed while reading this Cloudflare API call. Confirm before it runs."
if reason:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": reason,
    }}))
sys.exit(0)
'

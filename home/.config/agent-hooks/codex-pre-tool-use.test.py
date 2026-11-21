"""Run with python3 -I home/.config/agent-hooks/codex-pre-tool-use.test.py."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ADAPTER = Path(__file__).absolute().with_name("codex-pre-tool-use.py")
CASES = ADAPTER.parents[2] / ".claude/hooks/confirm-cloudflare-delete.cases.jsonl"
CLOUDFLARE_TOOL = "mcp__plugin_cloudflare_cloudflare_api__execute"
BASH_EVENT = {"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": "pwd"}}


class CodexPreToolUseTest(unittest.TestCase):
    def invoke(self, payload, adapter=ADAPTER):
        if isinstance(payload, dict):
            payload = json.dumps({"hook_event_name": "PreToolUse", **payload}).encode()
        result = subprocess.run(
            [sys.executable, "-I", str(adapter)], input=payload, capture_output=True, timeout=9,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        return result.stdout

    def assert_denied(self, output, reason):
        decision = json.loads(output)["hookSpecificOutput"]
        self.assertEqual(decision["hookEventName"], "PreToolUse")
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn(reason, decision["permissionDecisionReason"])
        return decision["permissionDecisionReason"]

    def test_safe_bash_and_unrelated_tools_are_silent(self):
        self.assertEqual(self.invoke(BASH_EVENT), b"")
        for tool in ("apply_patch", "mcp__cloudflare-api__search", "mcp__other__execute"):
            with self.subTest(tool=tool):
                self.assertEqual(self.invoke({"tool_name": tool}), b"")

    def test_malformed_input_is_denied(self):
        for payload in (b"", b"{malformed-json", b"\xff"):
            with self.subTest(payload=payload):
                self.assert_denied(self.invoke(payload), "could not read the tool call")
        for payload in (b"[]", b"null", {}, {"tool_name": 42}):
            with self.subTest(payload=payload):
                self.assert_denied(self.invoke(payload), "could not read the tool name")
        for change in ({"tool_input": []}, {"tool_input": {"command": 1}}, {"cwd": "relative"}):
            with self.subTest(change=change):
                self.assert_denied(self.invoke({**BASH_EVENT, **change}), "could not read the Bash command")

    def test_cloudflare_connector_requires_code(self):
        self.assert_denied(self.invoke({"tool_name": CLOUDFLARE_TOOL}), "could not find the code")

    def test_shared_cloudflare_cases(self):
        for line in CASES.read_text(encoding="utf-8").splitlines():
            case = json.loads(line)
            with self.subTest(case=case["id"]):
                output = self.invoke({"tool_name": CLOUDFLARE_TOOL, "tool_input": {"code": case["code"]}})
                if case["expect"] == "ask":
                    self.assert_denied(output, "This Cloudflare API call")
                else:
                    self.assertEqual(case["expect"], "allow")
                    self.assertEqual(output, b"")

    def test_shared_cloudflare_guard_preserves_the_reason_and_uses_stdin(self):
        code = 'async () => { const pad = "' + "x" * 200_000 + '"; '
        code += 'return cloudflare.request({ method: "DELETE", path: "/zones/fixture" }); }'
        for tool in (CLOUDFLARE_TOOL, "mcp__plugin_cloudflare_cloudflare-api__execute"):
            with self.subTest(tool=tool):
                self.assert_denied(
                    self.invoke({"tool_name": tool, "tool_input": {"code": code}}),
                    "DELETE to /zones/fixture",
                )

    def test_guard_failures_and_timeout_deny(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            adapter = home / ".config/agent-hooks" / ADAPTER.name
            adapter.parent.mkdir(parents=True)
            adapter.symlink_to(ADAPTER)
            guard = home / ".claude/hooks/confirm-destructive-git.sh"
            guard.parent.mkdir(parents=True)

            self.assert_denied(self.invoke(BASH_EVENT, adapter), "FileNotFoundError")

            for script, expected in (
                ("exit 9", "exited with status 9"),
                ("echo fixture-diagnostic >&2", "reported an error"),
                ("echo not-json", "returned an invalid decision"),
                ("echo '{}'", "returned an invalid decision"),
                ("printf ' '", "returned an invalid decision"),
                ('echo \'{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
                 '"permissionDecision":"allow","permissionDecisionReason":"test"}}\'',
                 "returned an invalid decision"),
                ("/bin/sleep 20 &\nwait", "timed out"),
            ):
                with self.subTest(expected=expected):
                    guard.write_text(f"#!/bin/bash\n{script}\n", encoding="utf-8")
                    guard.chmod(0o700)
                    reason = self.assert_denied(self.invoke(BASH_EVENT, adapter), expected)
                    self.assertNotIn("fixture-diagnostic", reason)


if __name__ == "__main__":
    unittest.main()

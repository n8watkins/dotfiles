"""Exercise install.sh against fixture homes. Run with python3 -I."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tomllib
import unittest


REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / "scripts/install-codex-hooks.py"
TEMPLATE = REPO / "home/.codex/config.hooks.toml"
BEGIN = "# >>> dotfiles: home/.codex/config.hooks.toml >>>"
END = "# <<< dotfiles: home/.codex/config.hooks.toml <<<"
START = """[[hooks.SessionStart]]

[[hooks.SessionStart.hooks]]
type = "command"
command = "/home/natkins/.config/agent-hooks/normalize-agents-md.sh 2>/dev/null || true"

"""
STOP = """[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "/home/natkins/.config/agent-hooks/normalize-agents-md.sh 2>/dev/null || true"

[[hooks.Stop.hooks]]
type = "command"
command = "/home/natkins/.config/agent-hooks/commit-reminder.sh 2>/dev/null || true"

"""
OLD_BLOCK = f"""{BEGIN}
# Previous dotfiles block.
[[hooks.PreToolUse]]
matcher = "Bash"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "/home/natkins/.local/bin/dcg"

[[hooks.SessionStart]]

[[hooks.SessionStart.hooks]]
type = "command"
command = "/home/natkins/.local/bin/agent-lock hook codex-session-start"
{END}
"""
OWNER_SETTINGS = "# Owner settings with trailing spaces  \n" + """model = "example-model"

[projects."/custom/project"]
trust_level = "trusted"

"""
TRUST = """[hooks.state]

[hooks.state."/home/natkins/.codex/config.toml:session_start:0:0"]
trusted_hash = "sha256:keep-this-start-hash"

[hooks.state."/home/natkins/.codex/config.toml:session_start:1:0"]
trusted_hash = "sha256:keep-this-lock-hash"

[hooks.state."/home/natkins/.codex/config.toml:stop:0:1"]
trusted_hash = "sha256:keep-this-reminder-hash"

"""
CUSTOM_HOOK = """# Leave this exact group in place.
[[hooks.PreToolUse]]
matcher = "Read"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "/usr/bin/true"
timeout = 42
"""


class InstallCodexHooksTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="codex install ")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.config = self.home / ".codex/config.toml"

    def run_install(self, *, full=True, check=True):
        if full:
            args = ["bash", str(REPO / "install.sh"), "--target-home", str(self.home)]
        else:
            args = [sys.executable, "-I", str(HELPER), str(TEMPLATE), str(self.home)]
        return subprocess.run(args, check=check, capture_output=True, text=True)

    def seed(self, contents):
        self.config.parent.mkdir()
        self.config.write_bytes(contents.encode())
        self.config.chmod(0o640)

    def assert_hook_groups(self):
        hooks = tomllib.loads(self.config.read_text())["hooks"]
        self.assertEqual(len(hooks["SessionStart"]), 2)
        self.assertEqual(len(hooks["Stop"]), 1)
        self.assertEqual(len(hooks["Stop"][0]["hooks"]), 2)
        for event, indices, names in (
            ("SessionStart", [(0, 0), (1, 0)], ["normalize-agents-md.sh", "agent-lock"]),
            ("Stop", [(0, 0), (0, 1)], ["normalize-agents-md.sh", "commit-reminder.sh"]),
            ("PreToolUse", [(0, 0), (1, 0)], ["dcg", "codex-pre-tool-use.py"]),
        ):
            for (group, hook), name in zip(indices, names, strict=True):
                command = hooks[event][group]["hooks"][hook]["command"]
                self.assertIn(str(self.home), command)
                self.assertIn(name, command)
        dcg, adapter = hooks["PreToolUse"][:2]
        self.assertRegex("Bash", dcg["matcher"])
        self.assertNotRegex("mcp__codex_apps__cloudflare_api__execute", dcg["matcher"])
        for tool in (
            "Bash", "mcp__codex_apps__cloudflare-api__execute",
            "mcp__codex_apps__cloudflare_api__execute",
        ):
            self.assertIsNotNone(re.fullmatch(adapter["matcher"], tool))
        self.assertIsNone(re.fullmatch(adapter["matcher"], "mcp__cloudflare_api__execute_more"))
        self.assertEqual(adapter["hooks"][0]["timeout"], 10)
        return hooks

    def assert_second_install_is_identical(self):
        data = self.config.read_bytes()
        modification_time = self.config.stat().st_mtime_ns
        self.run_install()
        self.assertEqual(self.config.read_bytes(), data)
        self.assertEqual(self.config.stat().st_mtime_ns, modification_time)

    def test_fresh_full_install_is_idempotent_and_does_not_add_trust(self):
        self.run_install()
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        hooks = self.assert_hook_groups()
        self.assertEqual(len(hooks["PreToolUse"]), 2)
        self.assertNotIn("state", hooks)
        source = REPO / "home/.config/agent-hooks"
        target = self.home / ".config/agent-hooks"
        for name in ("normalize-agents-md.sh", "commit-reminder.sh"):
            self.assertEqual((target / name).resolve(), source / name)
        for item in list(source.glob("*.py")) + list(source.glob("*.test.sh")):
            if re.search(r"(^test_|_test\.py$|\.test\.)", item.name):
                self.assertFalse((target / item.name).exists())
            else:
                self.assertEqual((target / item.name).resolve(), item)
        self.assert_second_install_is_identical()

    def test_migrates_observed_config_and_retains_unrelated_bytes(self):
        self.seed(OWNER_SETTINGS + START + STOP + TRUST + OLD_BLOCK + CUSTOM_HOOK)
        old_trust = tomllib.loads(self.config.read_text())["hooks"]["state"]
        self.run_install()
        hooks = self.assert_hook_groups()
        self.assertEqual(hooks["state"], old_trust)
        self.assertEqual(hooks["PreToolUse"][2]["hooks"][0]["timeout"], 42)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        data = self.config.read_text()
        self.assertTrue(data.startswith(OWNER_SETTINGS))
        self.assertTrue(data.endswith(CUSTOM_HOOK))
        self.assertIn(TRUST, data)
        self.assertEqual(data.count(BEGIN), 1)
        self.assertEqual(data.count(END), 1)
        self.assert_second_install_is_identical()

    def test_migrates_crlf_config_without_a_managed_block(self):
        self.seed((OWNER_SETTINGS + START + STOP.rstrip()).replace("\n", "\r\n"))
        self.run_install()
        self.assert_hook_groups()
        data = self.config.read_bytes()
        self.assertTrue(data.startswith(OWNER_SETTINGS.replace("\n", "\r\n").encode()))
        self.assertNotIn(b"\n", data.replace(b"\r\n", b""))
        self.assert_second_install_is_identical()

    def test_refuses_ambiguous_customizations_and_never_writes_config(self):
        custom_stop = STOP + '[[hooks.Stop.hooks]]\ntype = "command"\ncommand = "/usr/bin/true"\n'
        fixtures = {
            "custom matcher": START.replace(
                "[[hooks.SessionStart]]", '[[hooks.SessionStart]]\nmatcher = "startup"'
            ),
            "custom nested command": START + custom_stop,
            "skill inside managed block": OLD_BLOCK.replace(
                END, '[skills]\ncustom = "do not discard"\n' + END
            ),
            "orphan managed block": OLD_BLOCK.replace(END, ""),
            "fake legacy group in a string": "value = '''\n" + START + "'''\n",
        }
        for name, data in fixtures.items():
            with self.subTest(name=name):
                self.config.parent.mkdir(exist_ok=True)
                self.config.write_text(data)
                result = self.run_install(full=False, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Could not install Codex hooks", result.stderr)
                self.assertNotIn("do not discard", result.stderr)
                self.assertEqual(self.config.read_text(), data)

    def test_missing_guard_executables_block_and_dcg_keeps_its_reason(self):
        self.run_install(full=False)
        dcg, adapter = tomllib.loads(self.config.read_text())["hooks"]["PreToolUse"]
        dcg_command = dcg["hooks"][0]["command"]
        for command, message in (
            (dcg_command, "could not run dcg"),
            (adapter["hooks"][0]["command"], "could not run its PreToolUse guard"),
        ):
            result = subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn(message, result.stderr)

        dcg_file = self.home / ".local/bin/dcg"
        dcg_file.parent.mkdir(parents=True)
        dcg_file.write_text("#!/bin/sh\nprintf 'Blocked by dcg\\n' >&2\nexit 2\n")
        dcg_file.chmod(0o700)
        result = subprocess.run(["/bin/sh", "-c", dcg_command], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr, "Blocked by dcg\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Install the Codex hook block and migrate the exact earlier registrations."""

import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import tempfile
import tomllib


BEGIN = "# >>> dotfiles: home/.codex/config.hooks.toml >>>"
END = "# <<< dotfiles: home/.codex/config.hooks.toml <<<"
ORIGINAL_HOME = Path("/home/natkins")

LEGACY_LIFECYCLE = (
    """[[hooks.SessionStart]]

[[hooks.SessionStart.hooks]]
type = "command"
command = "/home/natkins/.config/agent-hooks/normalize-agents-md.sh 2>/dev/null || true"
""",
    """[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "/home/natkins/.config/agent-hooks/normalize-agents-md.sh 2>/dev/null || true"

[[hooks.Stop.hooks]]
type = "command"
command = "/home/natkins/.config/agent-hooks/commit-reminder.sh 2>/dev/null || true"
""",
)

# Keep old managed versions here when changing the template. A locally edited
# block needs the owner's review before it can be replaced.
LEGACY_MANAGED = """
[[hooks.PreToolUse]]
matcher = "Bash"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "/home/natkins/.local/bin/dcg"

[[hooks.SessionStart]]

[[hooks.SessionStart.hooks]]
type = "command"
command = "/home/natkins/.local/bin/agent-lock hook codex-session-start"
"""

COMMAND = re.compile(r'^command = "(?:/usr/bin/python3 -I )?/home/natkins/([^" ]+).*"$', re.M)


def commands_for_home(text, home):
    def render(match):
        relative = match.group(1)
        command = tomllib.loads(match.group(0))["command"]
        command = command.replace(
            str(ORIGINAL_HOME / relative), shlex.quote(str(home / relative)), 1
        )
        return "command = " + json.dumps(command, ensure_ascii=False)

    return COMMAND.sub(render, text)


def split_block(text):
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.rstrip("\r\n") == BEGIN]
    ends = [i for i, line in enumerate(lines) if line.rstrip("\r\n") == END]
    if not starts and not ends:
        return text, None, ""
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise ValueError("the dotfiles hook block markers are ambiguous")
    start, end = starts[0], ends[0]
    return "".join(lines[:start]), "".join(lines[start + 1:end]), "".join(lines[end + 1:])


def extract_known_groups(config, variants, tool_paths):
    """Separate exact hook groups for verification while retaining group order."""
    hooks = config.get("hooks", {})
    found = {}
    for event, groups in variants.items():
        if event not in hooks:
            continue
        if not isinstance(hooks[event], list):
            raise ValueError(f"unexpected format for {event} hook groups")
        retained = []
        for group in hooks[event]:
            if group in groups:
                found.setdefault(event, []).append(group)
            elif any(
                path in hook.get("command", "")
                for hook in group.get("hooks", [])
                for path in tool_paths
            ):
                raise ValueError(f"customized {event} hook uses a dotfiles hook command")
            else:
                retained.append(group)
        if retained:
            hooks[event] = retained
        else:
            del hooks[event]
    if not hooks:
        config.pop("hooks", None)
    return found


def updated_config(text, template, home):
    before, block, after = split_block(text)
    desired = commands_for_home(template, home)
    desired_hooks = tomllib.loads(desired)["hooks"]
    legacy_blocks = {
        commands_for_home(LEGACY_MANAGED, path) for path in (home, ORIGINAL_HOME)
    }
    parsed_legacy_blocks = [tomllib.loads(content) for content in legacy_blocks]
    if block is not None and tomllib.loads(block) not in [
        tomllib.loads(desired), *parsed_legacy_blocks
    ]:
        raise ValueError("the dotfiles hook block contains customized settings")

    legacy_sections = {
        commands_for_home(section, path)
        for section in LEGACY_LIFECYCLE
        for path in (home, ORIGINAL_HOME)
    }
    variants = {event: list(groups) for event, groups in desired_hooks.items()}
    for config in (*parsed_legacy_blocks, *(tomllib.loads(section) for section in legacy_sections)):
        for event, groups in config["hooks"].items():
            variants[event].extend(groups)
    tool_paths = {
        str(path / match.group(1))
        for source in (template, LEGACY_MANAGED, *LEGACY_LIFECYCLE)
        for match in COMMAND.finditer(source)
        for path in (home, ORIGINAL_HOME)
    }
    original = tomllib.loads(text)
    extract_known_groups(original, variants, tool_paths)

    for section in legacy_sections:
        for line_ending in ("\n", "\r\n"):
            section_text = section.rstrip("\n").replace("\n", line_ending)
            pattern = re.compile("^" + re.escape(section_text) + r"(?:\r?\n|$)", re.M)
            before = pattern.sub("", before)
            after = pattern.sub("", after)
    newline = "\r\n" if "\r\n" in text else "\n"
    if before and not before.endswith("\n"):
        before += newline
    contents = f"{BEGIN}\n{desired.rstrip()}\n{END}\n".replace("\n", newline)
    updated = before + contents + after
    parsed = tomllib.loads(updated)
    if extract_known_groups(parsed, variants, tool_paths) != desired_hooks:
        raise ValueError("a dotfiles hook is registered outside the recognized blocks")
    if parsed != original:
        raise ValueError("migrating hook blocks would change unrelated Codex config")
    return updated


def install(template_path, home):
    config = home / ".codex/config.toml"
    if config.is_symlink():
        raise ValueError("config.toml is a symlink")
    original = config.read_bytes() if config.exists() else b""
    updated = updated_config(original.decode(), template_path.read_text(), home).encode()
    if updated == original:
        return
    config.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=config.parent, delete=False) as pending:
        temporary = Path(pending.name)
        try:
            if config.exists():
                os.fchmod(pending.fileno(), stat.S_IMODE(config.stat().st_mode))
            pending.write(updated)
            pending.close()
            if (config.read_bytes() if config.exists() else b"") != original:
                raise ValueError("config.toml changed during installation")
            temporary.replace(config)
        finally:
            temporary.unlink(missing_ok=True)
    print(f"updated {config}")


if __name__ == "__main__":
    try:
        install(Path(sys.argv[1]), Path(sys.argv[2]))
    except tomllib.TOMLDecodeError:
        raise SystemExit("Could not install Codex hooks: config or migration has invalid TOML.") from None
    except (OSError, ValueError) as error:
        raise SystemExit(f"Could not install Codex hooks: {error}") from None

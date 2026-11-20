#!/usr/bin/env python3
"""Run the shared PreToolUse guards and translate their decisions for Codex."""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys


EVENT = "PreToolUse"
CLOUDFLARE_EXECUTE = re.compile(r"mcp__.*cloudflare[-_]api__execute")
GUARD_TIMEOUT = 5  # Keep this below the timeout Codex gives the adapter.

# Use the installation path, including when this script is a symlink.
GUARD_DIR = Path(__file__).absolute().parents[2] / ".claude" / "hooks"


def run_guard(name, payload):
    with subprocess.Popen(
        [str(GUARD_DIR / name)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    ) as process:
        try:
            stdout, stderr = process.communicate(json.dumps(payload).encode(), timeout=GUARD_TIMEOUT)
        except subprocess.TimeoutExpired:
            # Stop the guard and its children, including any git subprocesses.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            return f"{name} timed out."

    if process.returncode != 0:
        return f"{name} exited with status {process.returncode}."
    if stderr:
        # Parser errors may include tool arguments. Keep them out of hook output.
        return f"{name} reported an error."
    if not stdout:
        return None

    try:
        output = json.loads(stdout)["hookSpecificOutput"]
        reason = output["permissionDecisionReason"]
        if (output["hookEventName"] == EVENT
                and output["permissionDecision"] == "ask"
                and isinstance(reason, str) and reason.strip()):
            return reason
    except (ValueError, TypeError, KeyError):
        pass
    return f"{name} returned an invalid decision."


def block_reason(raw):
    try:
        event = json.loads(raw)
    except (ValueError, RecursionError):
        return "The Codex guard could not read the tool call."

    tool = event.get("tool_name") if isinstance(event, dict) else None
    if not isinstance(tool, str) or not tool:
        return "The Codex guard could not read the tool name."
    tool_input = event.get("tool_input")

    if tool == "Bash":
        command = tool_input.get("command") if isinstance(tool_input, dict) else None
        cwd = event.get("cwd")
        if not isinstance(command, str) or not isinstance(cwd, str) or not Path(cwd).is_absolute():
            return "The Codex guard could not read the Bash command or its working directory."
        # Omit permission_mode so Claude's auto-mode exception is never applied.
        return run_guard("confirm-destructive-git.sh", {"cwd": cwd, "tool_input": {"command": command}})
    if CLOUDFLARE_EXECUTE.fullmatch(tool):
        # Codex normalizes hyphens to underscores in MCP tool names.
        guard_tool = tool.replace("cloudflare_api__execute", "cloudflare-api__execute")
        return run_guard("confirm-cloudflare-delete.sh", {"tool_name": guard_tool, "tool_input": tool_input})
    return None


def main():
    try:
        reason = block_reason(sys.stdin.buffer.read())
    except Exception as error:
        reason = f"The Codex guard could not check this tool call ({type(error).__name__})."
    if reason is not None:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": EVENT,
            "permissionDecision": "deny",
            "permissionDecisionReason": f"{reason} Codex blocked this call. Report it to the owner.",
        }}))


if __name__ == "__main__":
    main()

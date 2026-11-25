#!/usr/bin/env python3
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import uuid


GEMINI_PHASES = {
    "BeforeAgent": ("UserPromptSubmit", "processing"),
    "BeforeTool": ("PreToolUse", "running_tool"),
    "AfterTool": ("PostToolUse", "processing"),
    "AfterAgent": ("Stop", "finished"),
    "SessionEnd": ("SessionEnd", "ended"),
}

CLAUDE_PHASES = {
    "PermissionRequest": ("PermissionRequest", "waiting_for_approval"),
    "PermissionDenied": ("PermissionDenied", "processing"),
    "PostToolUse": ("PostToolUse", "processing"),
    "PostToolUseFailure": ("PostToolUseFailure", "processing"),
    "Stop": ("Stop", "finished"),
    "SessionEnd": ("SessionEnd", "ended"),
}


def short_tool_name(value):
    if isinstance(value, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9_.:/-]{0,59}", value):
        return value
    return "工具权限"


def record(payload, event, directory, now, source="antigravity"):
    approval_action = None
    request_id = None
    if source in ("gemini", "claude"):
        identity = str(uuid.UUID(payload["session_id"]))
        cwd = payload.get("cwd", "")
        if source == "gemini" and event == "Notification":
            if payload.get("notification_type") != "ToolPermission":
                return False
            details = payload.get("details")
            details = details if isinstance(details, dict) else {}
            approval_action = short_tool_name(details.get("toolName") or details.get("tool_name"))
            request_id = details.get("callId") or details.get("tool_use_id")
            event, status = "PermissionRequest", "waiting_for_approval"
        else:
            event, status = (GEMINI_PHASES if source == "gemini" else CLAUDE_PHASES)[event]
            if status == "waiting_for_approval":
                approval_action = short_tool_name(payload.get("tool_name"))
                request_id = payload.get("tool_use_id")
    else:
        identity = str(uuid.UUID(payload["conversationId"]))
        workspaces = payload.get("workspacePaths") or []
        cwd = workspaces[0] if workspaces and isinstance(workspaces[0], str) else ""
        event, status = {
            "PreInvocation": ("PreInvocation", "processing"),
            "PostToolUse": ("PostToolUse", "processing"),
            "Stop": ("Stop", "finished"),
        }[event]
        if event == "Stop" and payload.get("fullyIdle") is False:
            event, status = "PostToolUse", "processing"
        elif event == "Stop" and payload.get("terminationReason") == "error":
            event, status = "StopFailure", "finished"
    item = dict(source=source, session_id=identity, event=event,
                status=status, cwd=cwd if isinstance(cwd, str) else "", observed_at=now)
    if approval_action:
        stable_id = request_id if isinstance(request_id, str) and 0 < len(request_id) <= 256 else uuid.uuid4().hex
        item["approval_request_id"] = hashlib.sha256((source + "|" + identity + "|" + stable_id).encode()).hexdigest()
        item["attention_action"] = approval_action
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    name = hashlib.sha256((source + "|" + identity).encode()).hexdigest()[:30]
    target = directory / (name + ".json")
    if source in ("gemini", "claude") and event == "SessionEnd":
        # Headless Gemini exits immediately after AfterAgent. Keep its Stop
        # card long enough for the bridge to read it and the app to retain it.
        try:
            previous = json.loads(target.read_text())
            if previous.get("event") == "Stop" and 0 <= now - previous["observed_at"] < 20:
                return False
        except (OSError, ValueError, KeyError, TypeError):
            pass
    with tempfile.NamedTemporaryFile("w", dir=directory, delete=False) as stream:
        temp = Path(stream.name)
        try:
            json.dump(item, stream)
            stream.flush()
            os.replace(temp, target)
        finally:
            temp.unlink(missing_ok=True)
    return approval_action is not None


def notify_bridge():
    # LaunchAgent coalesces filesystem events. An approval also wakes it now.
    try:
        subprocess.Popen(["/bin/launchctl", "kickstart", f"gui/{os.getuid()}/local.boringnotch.activity-bridge"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError:
        pass


if __name__ == "__main__":
    try:
        observed = record(json.loads(sys.stdin.buffer.read(256 * 1024)), sys.argv[1],
                          Path.home() / ".multiagent-notch/session-state", time.time(),
                          sys.argv[2] if len(sys.argv) > 2 else "antigravity")
        if observed:
            notify_bridge()
    except (ValueError, OSError, KeyError, TypeError, IndexError):
        pass
    print('{"decision":"stop"}' if sys.argv[1:] in (["Stop"], ["Stop", "antigravity"]) else "{}")

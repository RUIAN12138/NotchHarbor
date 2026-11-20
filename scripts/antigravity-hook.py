#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import uuid


def record(payload, event, directory, now, source="antigravity"):
    if source == "gemini":
        identity = str(uuid.UUID(payload["session_id"]))
        cwd = payload.get("cwd", "")
        event, status = {
            "BeforeAgent": ("UserPromptSubmit", "processing"),
            "BeforeTool": ("PreToolUse", "running_tool"),
            "AfterTool": ("PostToolUse", "processing"),
            "AfterAgent": ("Stop", "finished"),
            "SessionEnd": ("SessionEnd", "ended"),
        }[event]
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
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    name = hashlib.sha256((source + "|" + identity).encode()).hexdigest()[:30]
    target = directory / (name + ".json")
    if source == "gemini" and event == "SessionEnd":
        # Headless Gemini exits immediately after AfterAgent. Keep its Stop
        # card long enough for the bridge to read it and the app to retain it.
        try:
            previous = json.loads(target.read_text())
            if previous.get("event") == "Stop" and 0 <= now - previous["observed_at"] < 20:
                return
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


if __name__ == "__main__":
    try:
        record(json.loads(sys.stdin.read()), sys.argv[1],
               Path.home() / ".multiagent-notch/session-state", time.time(),
               sys.argv[2] if len(sys.argv) > 2 else "antigravity")
    except (ValueError, OSError, KeyError, TypeError, IndexError):
        pass
    print('{"decision":"stop"}' if sys.argv[1:] in (["Stop"], ["Stop", "antigravity"]) else "{}")

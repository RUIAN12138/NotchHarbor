#!/usr/bin/env python3
"""Local stdio MCP adapter for the Notch Harbor Agent activity bridge."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

VERSIONS = ("2025-03-26", "2024-11-05", "2025-06-18", "2025-11-25")
PHASES = {
    "working": ("UserPromptSubmit", "processing"),
    "question": ("Notification", "waiting_for_input"),
    "approval": ("PermissionRequest", "waiting_for_approval"),
    "completed": ("Stop", "finished"),
    "failed": ("StopFailure", "failed"),
    "clear": ("SessionEnd", "ended"),
}
TOOLS = [
    {
        "name": "notch_harbor_status",
        "description": "Check whether the local Notch Harbor app and its Agent activity bridge are available.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "set_doubao_activity",
        "description": "Show a Doubao CLI task status on Notch Harbor. Use the real numeric session ID if known. Send only a short title, never the transcript or secrets. Approval status displays a request indicator; it does not approve the request.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "phase": {"type": "string", "enum": list(PHASES)},
                "session_id": {"type": "string", "pattern": "^[1-9][0-9]{0,19}$"},
                "title": {"type": "string", "maxLength": 80},
                "request_id": {"type": "string", "minLength": 1, "maxLength": 96},
                "action": {"type": "string", "maxLength": 60, "description": "Short user-facing action label, without commands, arguments or secrets."},
            },
            "required": ["phase"],
            "additionalProperties": False,
        },
    },
]
activity_schema = TOOLS[1]["inputSchema"]
TOOLS.append({
    "name": "set_agent_activity",
    "description": "Publish your own task status to Notch Harbor. Use a stable source and session ID for updates and clear. A request status is display-only.",
    "inputSchema": {
        **activity_schema,
        "properties": {
            **activity_schema["properties"],
            "source": {"type": "string", "pattern": "^[a-z][a-z0-9-]{0,31}$"},
            "name": {"type": "string", "maxLength": 28},
            "session_id": {"type": "string", "maxLength": 96},
        },
        "required": ["source", "session_id", "phase"],
    },
})



def app_status():
    service = f"gui/{os.getuid()}/local.boringnotch.activity-bridge"
    return {
        "app_running": subprocess.run(
            ["/usr/bin/pgrep", "-xq", "NotchHarbor"], capture_output=True, timeout=3
        ).returncode == 0,
        "bridge_registered": subprocess.run(
            ["/bin/launchctl", "print", service], capture_output=True, timeout=3
        ).returncode == 0,
    }


def set_activity(args, root, forced_source=None):
    phase = args.get("phase")
    session = args.get("session_id")
    title = args.get("title", "")
    if not isinstance(phase, str) or phase not in PHASES or not isinstance(title, str) or len(title) > 80:
        raise ValueError("无效的状态或标题")
    source = forced_source or args.get("source")
    name = args.get("name", "")
    if not isinstance(source, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", source):
        raise ValueError("source 必须是稳定的英文标识")
    if not isinstance(name, str) or len(name) > 28:
        raise ValueError("name 最多 28 个字符")
    if forced_source is None and session is None:
        raise ValueError("通用 Agent 必须提供稳定的 session_id")
    if session is not None:
        if not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,95}", session):
            raise ValueError("无效的会话标识")
        if source == "doubao" and (not re.fullmatch(r"[1-9][0-9]{0,19}", session) or int(session) > 2**64 - 1):
            raise ValueError("豆包需要真实的数字会话 ID")
    request_id, action = args.get("request_id"), args.get("action", "")
    if request_id is not None and (not isinstance(request_id, str) or not 1 <= len(request_id) <= 96):
        raise ValueError("request_id 必须是短标识")
    if not isinstance(action, str) or len(action) > 60:
        raise ValueError("action 最多 60 个字符")
    event, status = PHASES[phase]
    # Generic callers report status only. They cannot impersonate native
    # transcript providers or trigger their account-backed reply generation.
    stored_source = "doubao" if source == "doubao" else "mcp-" + source
    identity = session or "mcp-current"
    digest = hashlib.sha256((source + "|" + identity).encode()).hexdigest()
    row = {
        "source": stored_source, "session_id": identity, "event": event,
        "status": status, "observed_at": time.time(), "session_title": " ".join(title.split()),
        "agent_name": " ".join(name.split()) or source,
    }
    if phase in ("approval", "question"):
        if request_id is not None:
            row["approval_request_id"] = hashlib.sha256(request_id.encode()).hexdigest()
        if action:
            row["attention_action"] = " ".join(action.split())
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=root, delete=False) as file:
        staging = Path(file.name)
        try:
            json.dump(row, file, ensure_ascii=False)
            file.close()
            staging.replace(root / f"notchharbor-mcp-{digest}.json")
        finally:
            staging.unlink(missing_ok=True)
    return {"queued": True, "phase": phase, "has_session_id": session is not None}


def dispatch(message, root):
    method = message.get("method")
    params = message.get("params", {})
    if not isinstance(params, dict):
        raise ValueError("params 必须是对象")
    if method == "initialize":
        version = params.get("protocolVersion")
        return {
            "protocolVersion": version if version in VERSIONS else VERSIONS[-1],
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "notch-harbor", "version": "1.0.0"},
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments", {})
        try:
            if not isinstance(args, dict):
                raise ValueError("arguments 必须是对象")
            if name == "notch_harbor_status":
                data = app_status()
            elif name == "set_doubao_activity":
                data = set_activity(args, root, "doubao")
            elif name == "set_agent_activity":
                data = set_activity(args, root)
            else:
                raise ValueError("未知工具")
            return {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}]}
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            return {"isError": True, "content": [{"type": "text", "text": str(error)}]}
    raise KeyError(method)


def main():
    root = Path.home() / ".multiagent-notch/session-state"
    for line in sys.stdin:
        message = {}
        try:
            message = json.loads(line)
            if not isinstance(message, dict):
                raise ValueError("请求必须是对象")
            if "id" not in message:
                continue
            response = {"result": dispatch(message, root)}
        except (ValueError, KeyError) as error:
            code = -32601 if isinstance(error, KeyError) else -32602
            response = {"error": {"code": code, "message": str(error)}}
        print(json.dumps({"jsonrpc": "2.0", "id": message.get("id") if isinstance(message, dict) else None,
                          **response}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()

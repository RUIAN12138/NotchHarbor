#!/usr/bin/env python3
"""Route live Codex PermissionRequest events to Notch Harbor."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid

LIFETIME = 55
NOTIFIER = Path(__file__).with_name("activity-notify")
def notify():
    try:
        subprocess.run([str(NOTIFIER), "--codex-approval"], input=b"", timeout=1,
                       capture_output=True, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass


def make_request(event, now, pid):
    if not isinstance(event, dict) or event.get("hook_event_name") != "PermissionRequest":
        return None
    tool_input = event.get("tool_input")
    tool = event.get("tool_name")
    if not isinstance(tool, str) or not tool or len(tool) > 96:
        return None
    session_id = str(uuid.UUID(event["session_id"]))
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    cwd = tool_input.get("workdir") or event.get("cwd") or ""
    reason = tool_input.get("description") or tool_input.get("justification") or tool_input.get("reason") or ""
    command = tool_input.get("command")
    # A complete plain shell command can be reviewed here. Requests for a
    # particular network host, permission set, or another tool stay in Codex.
    allowed_keys = {"command", "description", "justification", "cwd", "workdir"}
    can_decide = (tool == "Bash" and set(tool_input) <= allowed_keys
                  and isinstance(reason, str) and not reason.lstrip().lower().startswith("network-access ")
                  and isinstance(command, str) and 0 < len(command) <= 2000
                  and not any(unicodedata.category(c) in ("Cc", "Cf") and c not in "\t\n" for c in command)
                  and isinstance(cwd, str) and cwd.startswith("/") and len(cwd) <= 512
                  and not any(unicodedata.category(c) in ("Cc", "Cf") for c in cwd))
    return dict(id=str(uuid.uuid4()), sessionID=session_id, tool=tool,
                cwd=cwd[:512] if isinstance(cwd, str) else "",
                reason=reason[:240] if isinstance(reason, str) else "",
                command=command if can_decide else None, createdAt=now,
                expires=now+LIFETIME, pid=pid)


def private_folder(root):
    for folder in (root.parent, root):
        folder.mkdir(mode=0o700, exist_ok=True)
        info = folder.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise OSError("Approval directory must be private")
    return root


def write_request(path, request):
    with tempfile.NamedTemporaryFile(dir=path.parent) as stream:
        # The temporary name and the published name never expose a partial request.
        stream.write(json.dumps(request, ensure_ascii=False).encode())
        stream.flush()
        os.link(stream.name, path)


def read_choice(path):
    try:
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 8:
                return None
            return {b"allow": "allow", b"deny": "deny", b"native": "native"}.get(stream.read(9))
    except OSError:
        return None


def wait_for_choice(request, root, on_change, parent, pause=time.sleep, clock=time.time):
    incoming = root / (request["id"] + ".json")
    outgoing = incoming.with_suffix(".decision")
    ready = incoming.with_suffix(".ready")
    write_request(incoming, request)
    try:
        on_change()
        ack_deadline = min(request["expires"], clock() + 3)
        while clock() < ack_deadline and not ready.exists():
            pause(0.1)
        if not ready.exists():
            return None
        while clock() < request["expires"] and os.getppid() == parent:
            choice = read_choice(outgoing)
            if choice in ("deny", "native") or (choice == "allow" and request["command"] is not None):
                return choice
            pause(0.15)
    finally:
        incoming.unlink(missing_ok=True)
        outgoing.unlink(missing_ok=True)
        ready.unlink(missing_ok=True)
        on_change()
    return None


def hook_output(choice):
    if choice not in ("allow", "deny"):
        return None
    decision = {"behavior": choice}
    if choice == "deny":
        decision["message"] = "Denied by the user in Notch Harbor."
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}


def main():
    try:
        parent = os.getppid()
        request = make_request(json.loads(sys.stdin.buffer.read(256 * 1024)), time.time(), os.getpid())
        if request is None:
            return
        root = private_folder(Path.home() / ".multiagent-notch" / "notch-harbor-approvals")
        choice = wait_for_choice(request, root, notify, parent)
        if result := hook_output(choice):
            print(json.dumps(result), flush=True)
    except (OSError, TypeError, ValueError, KeyError, subprocess.SubprocessError):
        # A missing app, bad packet, or expired request falls back to Codex.
        return


if __name__ == "__main__":
    main()

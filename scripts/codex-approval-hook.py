#!/usr/bin/env python3
"""Route live command approvals to Notch Harbor."""
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid

LIFETIME = 55
NOTIFIER = Path(__file__).with_name("activity-notify")


def codex_is_asking_user(event, codex_home):
    """Match this session's latest recorded turn, not global config defaults."""
    try:
        turn_id = uuid.UUID(event["turn_id"])
        session_id = uuid.UUID(event["session_id"])
        path = Path(event["transcript_path"])
        sessions = (codex_home / "sessions").resolve()
        if (not path.is_absolute() or not path.resolve().is_relative_to(sessions)
                or not path.name.endswith(str(session_id) + ".jsonl")):
            return False
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                return False
            meta = json.loads(stream.readline(128 * 1024))
            if meta.get("type") != "session_meta" or uuid.UUID(meta["payload"]["id"]) != session_id:
                return False
            first = stream.tell()
            tail = max(first, info.st_size - 2 * 1024 * 1024)
            stream.seek(tail)
            if tail > first:
                stream.readline(2 * 1024 * 1024)
            raw = stream.read(2 * 1024 * 1024)
            for line in reversed(raw.splitlines()):
                try:
                    record = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if not isinstance(record, dict) or record.get("type") != "turn_context":
                    continue
                payload = record.get("payload", {})
                return (uuid.UUID(payload["turn_id"]) == turn_id
                        and payload.get("approvals_reviewer") == "user"
                        and payload.get("approval_policy") not in (None, "never"))
    except (OSError, KeyError, AttributeError, TypeError, ValueError):
        pass
    return False


def notify():
    try:
        subprocess.run([str(NOTIFIER), "--codex-approval"], input=b"", timeout=1,
                       capture_output=True, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass


def make_request(event, now, pid, provider="codex"):
    if provider not in ("codex", "claude"):
        return None
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
    raw_cmd = tool_input.get("command") if "command" in tool_input else tool_input.get("cmd")
    if isinstance(raw_cmd, list) and raw_cmd and all(isinstance(part, str) for part in raw_cmd):
        command = shlex.join(raw_cmd)
    else:
        command = raw_cmd
    # A complete plain command or patch can be reviewed here. Requests for a
    # particular network host, permission set, or another tool stay in Codex.
    allowed_keys = {
        "command", "cmd", "description", "justification", "reason",
        "cwd", "workdir", "timeout", "timeout_ms", "login", "tty",
        "sandbox_permissions", "prefix_rule",
    }
    if provider == "claude":
        allowed_keys |= {"run_in_background"}
    is_shell = tool in ("Bash", "shell", "shell_command", "exec_command")
    is_patch = provider == "codex" and tool == "apply_patch"
    if is_patch and isinstance(command, str):
        patch = command.strip()
        is_patch = patch.startswith("*** Begin Patch\n") and patch.endswith("\n*** End Patch")
    can_decide = ((is_shell or is_patch) and set(tool_input) <= allowed_keys
                  and isinstance(reason, str) and not reason.lstrip().lower().startswith("network-access ")
                  and isinstance(command, str) and 0 < len(command.encode()) <= (12000 if is_patch else 4000)
                  and not any(unicodedata.category(c) in ("Cc", "Cf") and c not in "\t\n" for c in command)
                  and isinstance(cwd, str) and cwd.startswith("/") and len(cwd) <= 512
                  and not any(unicodedata.category(c) in ("Cc", "Cf") for c in cwd))
    if provider == "claude" and not can_decide:
        # The existing passive hook continues to surface the request.
        return None
    display_tool = "文件变更" if is_patch else ("Bash" if is_shell else tool)
    return dict(id=str(uuid.uuid4()), sessionID=session_id, tool=display_tool, provider=provider,
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
        ack_deadline = min(request["expires"], clock() + 5)
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
        provider = sys.argv[1] if len(sys.argv) == 2 else "codex"
        event = json.loads(sys.stdin.buffer.read(256 * 1024))
        request = make_request(event, time.time(), os.getpid(), provider)
        if request is None:
            return
        if provider == "codex":
            codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()
            if not codex_is_asking_user(event, codex_home):
                return
        elif os.environ.get("CLAUDE_CODE_SESSION_ATTENDED") == "0":
            return
        root = private_folder(Path.home() / ".multiagent-notch" / "notch-harbor-approvals")
        choice = wait_for_choice(request, root, notify, parent)
        if result := hook_output(choice):
            print(json.dumps(result), flush=True)
        if choice is not None:
            # Signal that the live hook consumed the choice after emitting the decision.
            receipt = root / (request["id"] + ".receipt")
            fd = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(choice)
    except (OSError, TypeError, ValueError, KeyError, subprocess.SubprocessError):
        # A missing app, bad packet, or expired request falls back to Codex.
        return


if __name__ == "__main__":
    main()

"""Regression coverage for the production Codex approval hook and its installer."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import uuid


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


hook = load("codex-approval-hook")
installer = load("install-codex-approval-hook")
event = dict(hook_event_name="PermissionRequest", session_id=str(uuid.uuid4()),
             tool_name="Bash", cwd="/tmp/example",
             tool_input=dict(command="/usr/bin/true", description="Test only"))
assert hook.make_request(dict(event, hook_event_name="PreToolUse"), 1, os.getpid()) is None
for extra in (dict(description="network-access https://example.com:443"),
              dict(permissions={"network": True}), dict(command="true\u202e")):
    unsupported = dict(event, tool_input=dict(event["tool_input"], **extra))
    assert hook.make_request(unsupported, 1, os.getpid())["command"] is None

with tempfile.TemporaryDirectory() as directory:
    root = hook.private_folder(Path(directory) / "private" / "approvals")

    def run(payload, input_choice, ready=True):
        now = [0.0]
        observed = []
        request = hook.make_request(payload, now[0], os.getpid())
        request_file = root / (request["id"] + ".json")

        def notify():
            observed.append(request_file.exists())
            if request_file.exists():
                assert json.loads(request_file.read_text()) == request
                if ready:
                    request_file.with_suffix(".ready").touch()
                if input_choice:
                    request_file.with_suffix(".decision").write_text(input_choice)

        def pause(duration):
            now[0] += duration

        result = hook.wait_for_choice(request, root, notify, os.getppid(), pause, lambda: now[0])
        assert observed == [True, False] and not list(root.iterdir()), observed
        return hook.hook_output(result)

    for choice in ("allow", "deny"):
        assert run(event, choice)["hookSpecificOutput"]["decision"]["behavior"] == choice
    assert run(event, "native") is None
    assert run(event, None) is None
    assert run(event, "allow", ready=False) is None
    assert run(dict(event, tool_name="request_permissions"), "allow") is None

    config = Path(directory) / "hooks.json"
    mock_agent_hud = {"hooks": [{"type": "command", "command": "/usr/bin/true"}]}
    original = {"description": "Keep me", "hooks": {"PermissionRequest": [mock_agent_hud]}}
    config.write_text(json.dumps(original))
    for _ in range(2):
        installer.install(config, root / "notch-hook.py")
    assert json.loads(config.read_text())["hooks"]["PermissionRequest"][0] == mock_agent_hud
    assert len(json.loads(config.read_text())["hooks"]["PermissionRequest"]) == 2
    assert json.loads(next(config.parent.glob("hooks-before-notch-harbor-*.json")).read_text()) == original

print("PASS: user decisions, timeout, no app, unsupported permissions fallback, and preserving pre-existing hooks")

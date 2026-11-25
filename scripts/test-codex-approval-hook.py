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
    codex_home = Path(directory)
    sessions = codex_home / "sessions"
    sessions.mkdir()
    live_turn = str(uuid.uuid4())
    later_turn = str(uuid.uuid4())
    transcript = sessions / ("rollout-" + event["session_id"] + ".jsonl")
    review_event = dict(event, transcript_path=str(transcript), turn_id=live_turn)
    metadata = {"type": "session_meta", "payload": {"id": event["session_id"]}}

    def transcript_with(*reviewers):
        rows = [metadata]
        for index, reviewer in enumerate(reviewers):
            rows.append({"type": "turn_context", "payload": {
                "turn_id": live_turn if index == 0 else later_turn,
                "approvals_reviewer": reviewer,
                "approval_policy": "on-request",
            }})
        transcript.write_text("".join(json.dumps(row) + "\n" for row in rows))

    transcript_with("user")
    assert hook.codex_is_asking_user(review_event, codex_home)
    assert not hook.codex_is_asking_user(dict(review_event, session_id=str(uuid.uuid4())), codex_home)
    transcript_with("auto_review")
    assert not hook.codex_is_asking_user(review_event, codex_home)
    transcript_with("user", "user")
    assert not hook.codex_is_asking_user(review_event, codex_home)
    assert hook.codex_is_asking_user(dict(review_event, turn_id=later_turn), codex_home)
    transcript_with(None)
    assert not hook.codex_is_asking_user(review_event, codex_home)

with tempfile.TemporaryDirectory() as directory:
    root = hook.private_folder(Path(directory) / "private" / "approvals")

    def run(payload, input_choice, ready=True, provider="codex"):
        now = [0.0]
        observed = []
        request = hook.make_request(payload, now[0], os.getpid(), provider)
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
    for choice in ("allow", "deny"):
        assert run(event, choice, provider="claude")["hookSpecificOutput"]["decision"]["behavior"] == choice
    assert hook.make_request(dict(event, tool_name="Write"), 1, os.getpid(), "claude") is None
    assert hook.make_request(event, 1, os.getpid(), "gemini") is None
    assert hook.make_request(event, 1, os.getpid(), "claude")["provider"] == "claude"
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

    claude = Path(directory) / "claude-settings.json"
    claude.write_text(json.dumps(original))
    for _ in range(2):
        installer.install(claude, root / "notch-hook.py", "claude")
    entries = json.loads(claude.read_text())["hooks"]["PermissionRequest"]
    assert entries[0] == mock_agent_hud and len(entries) == 2
    assert entries[-1]["matcher"] == "Bash" and entries[-1]["hooks"][0]["command"].endswith(" claude")

print("PASS: user decisions, timeout, no app, unsupported permissions fallback, and preserving pre-existing hooks")

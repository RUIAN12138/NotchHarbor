#!/usr/bin/env python3
"""Register one Notch Harbor command approval hook."""
import argparse
import json
import os
from pathlib import Path
import shlex
import tempfile


def install(path, script, provider="codex"):
    if path.is_symlink():
        raise ValueError("Refusing to replace a hooks.json symlink")
    original = path.read_bytes() if path.exists() else None
    config = json.loads(original) if original is not None else {}
    groups = config.setdefault("hooks", {}).setdefault("PermissionRequest", [])
    arguments = ["/usr/bin/python3", str(script)]
    if provider == "claude":
        arguments.append("claude")
    hook = {"type": "command", "command": shlex.join(arguments), "timeout": 65,
            "statusMessage": "Notch Harbor 审批"}
    if any(hook in group.get("hooks", []) for group in groups):
        return
    group = {"hooks": [hook]}
    if provider == "claude":
        group["matcher"] = "Bash"
    groups.append(group)
    path.parent.mkdir(parents=True, exist_ok=True)
    if original is not None:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix="hooks-before-notch-harbor-",
                                         suffix=".json", delete=False) as backup:
            backup.write(original)
        print("Backup:", backup.name)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
        output.write((json.dumps(config, ensure_ascii=False, indent=2) + "\n").encode())
    if path.is_symlink() or (path.read_bytes() if path.exists() else None) != original:
        Path(output.name).unlink()
        raise RuntimeError("hooks.json changed while preparing the update")
    os.replace(output.name, path)
    print(path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", choices=("codex", "claude"), default="codex")
    provider = parser.parse_args().provider
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()
    location = codex_home / "hooks.json" if provider == "codex" else Path.home() / ".claude/settings.json"
    install(location, Path(__file__).with_name("codex-approval-hook.py").resolve(), provider)

#!/usr/bin/env python3
"""Register one Notch Harbor hook alongside existing Codex hooks."""
import json
import os
from pathlib import Path
import shlex
import tempfile


def install(path, script):
    if path.is_symlink():
        raise ValueError("Refusing to replace a hooks.json symlink")
    original = path.read_bytes() if path.exists() else None
    config = json.loads(original) if original is not None else {}
    groups = config.setdefault("hooks", {}).setdefault("PermissionRequest", [])
    command = shlex.join(["/usr/bin/python3", str(script)])
    hook = {"type": "command", "command": command, "timeout": 65,
            "statusMessage": "Notch Harbor 审批"}
    if any(hook in group.get("hooks", []) for group in groups):
        return
    groups.append({"hooks": [hook]})
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
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()
    install(codex_home / "hooks.json", Path(__file__).with_name("codex-approval-hook.py").resolve())

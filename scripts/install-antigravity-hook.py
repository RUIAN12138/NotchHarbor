#!/usr/bin/env python3
"""Install passive Boring Notch hooks without replacing other agent hooks."""
import argparse
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile

SCRIPT = Path(__file__).with_name('antigravity-hook.py').resolve()
GROUP = 'boringnotch-activity'


def handler(event, provider='antigravity'):
    return {'type': 'command', 'command': shlex.join([sys.executable, str(SCRIPT), event, provider]),
            'timeout': 3 if provider == 'antigravity' else 3000}


def install(config, provider):
    if config.is_symlink():
        raise ValueError(f'Refusing symlink: {config}')
    existing = config.read_bytes() if config.exists() else None
    data = json.loads(existing) if existing is not None else {}
    if not isinstance(data, dict):
        raise ValueError(f'Expected JSON object: {config}')
    if provider == 'antigravity':
        for event in ('PreInvocation', 'PostToolUse', 'Stop'):
            old = data.get(event)
            if not isinstance(old, list):
                continue
            kept = []
            for entry in old:
                if isinstance(entry, dict) and isinstance(entry.get('hooks'), list):
                    remaining = [h for h in entry['hooks'] if not ours(h)]
                    if remaining:
                        kept.append(dict(entry, hooks=remaining))
                elif not ours(entry):
                    kept.append(entry)
            if kept:
                data[event] = kept
            else:
                data.pop(event, None)
        data[GROUP] = {
            'PreInvocation': [handler('PreInvocation')],
            'PostToolUse': [{'matcher': '.*', 'hooks': [handler('PostToolUse')]}],
            'Stop': [handler('Stop')],
        }
    else:
        hooks = data.setdefault('hooks', {})
        for event in ('BeforeAgent', 'BeforeTool', 'AfterTool', 'AfterAgent', 'SessionEnd'):
            entries = hooks.setdefault(event, [])
            command = handler(event, 'gemini')
            if not any(isinstance(e, dict) and command in e.get('hooks', []) for e in entries):
                entries.append({'matcher': '.*', 'hooks': [command]})
    updated = (json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode()
    if updated != existing:
        config.parent.mkdir(parents=True, exist_ok=True)
        if existing is not None:
            with tempfile.NamedTemporaryFile(prefix=config.stem+'-before-boringnotch-', suffix='.json', dir=config.parent, delete=False) as backup:
                backup.write(existing)
                print('Backup:', backup.name)
        with tempfile.NamedTemporaryFile(dir=config.parent, delete=False) as output:
            output.write(updated)
            output.flush()
            os.replace(output.name, config)
    print(config)


def ours(entry):
    return isinstance(entry, dict) and str(SCRIPT) in entry.get('command', '')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--provider', choices=('antigravity', 'gemini'), default='antigravity')
    args = parser.parse_args()
    install(Path.home() / '.gemini' / ('config/hooks.json' if args.provider == 'antigravity' else 'settings.json'), args.provider)

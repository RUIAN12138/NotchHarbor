"""Bounded title and tool-name metadata adapter for Codex session rows.
Never returns tool arguments, output or messages.
"""
import json
from datetime import datetime, timedelta
import hashlib
import os
from pathlib import Path
import re
import sqlite3
from contextlib import closing
import stat
import time
import uuid


def enrich_session_titles(items, index):
    by_id = {item['sessionID']: item for item in items
             if item.get('source') == 'codex' and item.get('sessionID')}
    if not by_id:
        return
    try:
        fd = os.open(index, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                return
            offset = max(0, info.st_size - 524288)
            stream.seek(offset)
            lines = stream.read(524288).splitlines()
            for line in reversed(lines[1:] if offset else lines):
                try:
                    entry = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if not isinstance(entry, dict):
                    continue
                identity = entry.get('id')
                name = entry.get('thread_name')
                if not isinstance(identity, str) or not isinstance(name, str) or identity.lower() not in by_id:
                    continue
                title = ' '.join(name.split())[:80]
                if title:
                    by_id.pop(identity.lower())['sessionTitle'] = title
                if not by_id:
                    break
    except OSError:
        return


def matches_session(name, identity):
    return name.endswith('.jsonl') and identity in re.findall(
        r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', name.lower())


def activity_details(path, lifecycle=None, tail_bytes=131072):
    steps = {}
    tokens = None
    latest_tool = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                return None, [], None
            offset = max(0, info.st_size-tail_bytes)
            stream.seek(offset)
            lines = stream.read(tail_bytes).splitlines()
            if offset and lines:
                lines.pop(0)
            for line in lines:
                if not any(marker in line for marker in (b'"function_call"', b'"custom_tool_call"',
                    b'"function_call_output"', b'"custom_tool_call_output"', b'"token_count"',
                    b'"task_started"', b'"task_complete"', b'"turn_aborted"')):
                    continue
                try:
                    row = json.loads(line)
                    payload = row.get('payload', {})
                    kind = payload.get('type')
                    if lifecycle is not None and row.get('type') == 'event_msg' and kind in (
                        'task_started', 'task_complete', 'turn_aborted'
                    ):
                        timestamp = row.get('timestamp')
                        if isinstance(timestamp, str):
                            date = datetime.fromisoformat(timestamp)
                            if date.tzinfo:
                                lifecycle[:] = [(kind, date.timestamp())]
                    name = payload.get('name')
                    identity = payload.get('call_id')
                    if kind in ('function_call', 'custom_tool_call') and isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9_.-]{1,96}', name):
                        latest_tool = name
                        if isinstance(identity, str) and 0 < len(identity) <= 150:
                            step = dict(id=hashlib.sha256(identity.encode()).hexdigest()[:16],
                                        tool=name, returned=False)
                            timestamp = row.get('timestamp')
                            if isinstance(timestamp, str):
                                try:
                                    date = datetime.fromisoformat(timestamp)
                                    if date.tzinfo:
                                        step['startedAt'] = date.timestamp()
                                except (ValueError, OverflowError):
                                    pass
                            steps[identity] = step
                    elif kind in ('function_call_output', 'custom_tool_call_output') and isinstance(identity, str) and identity in steps:
                        steps[identity]['returned'] = True
                    elif kind == 'token_count' and isinstance(payload.get('info'), dict):
                        usage = payload['info'].get('total_token_usage')
                        if isinstance(usage, dict):
                            total = usage.get('total_tokens')
                            if type(total) is int and 0 < total <= 10_000_000_000:
                                tokens = dict(total=total)
                                for input_key, output_key in [('input_tokens', 'input'), ('output_tokens', 'output')]:
                                    count = usage.get(input_key)
                                    if type(count) is int and 0 <= count <= total:
                                        tokens[output_key] = count
                except (ValueError, TypeError, AttributeError, OverflowError):
                    continue
    except OSError:
        pass
    return latest_tool, list(steps.values())[-6:], tokens


def last_tool(path):
    return activity_details(path)[0]


def latest_codex_lifecycle(stream, size):
    """Walk back past large tool results to find the latest lifecycle event."""
    end = size
    minimum = max(0, size - 8 * 1024 * 1024)
    fragment = b''
    while end > minimum:
        start = max(minimum, end - 64 * 1024)
        stream.seek(start)
        lines = (stream.read(end - start) + fragment).split(b'\n')
        fragment = lines.pop(0) if start > 0 else b''
        for line in reversed(lines):
            if not any(marker in line for marker in (b'"task_started"', b'"task_complete"', b'"turn_aborted"')):
                continue
            try:
                row = json.loads(line)
                kind = row.get('payload', {}).get('type')
                if row.get('type') == 'event_msg' and kind in ('task_started', 'task_complete', 'turn_aborted'):
                    timestamp = datetime.fromisoformat(row['timestamp'])
                    if timestamp.tzinfo:
                        return kind, timestamp.timestamp()
            except (AttributeError, KeyError, ValueError, TypeError, OverflowError):
                continue
        end = start
    return None


RECENT_SESSION_LIFETIME = 15 * 60
CODEX_RUNNING_LIFETIME = 6 * 60


def indexed_codex_paths(root, now):
    """Find recently updated threads whose rollouts live in old date folders."""
    databases = []
    for path in root.parent.glob('state_*.sqlite'):
        version = re.fullmatch(r'state_(\d+)\.sqlite', path.name)
        try:
            info = path.lstat()
            if version and stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid():
                databases.append((int(version[1]), path))
        except OSError:
            continue
    for _, database in sorted(databases, reverse=True):
        try:
            with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=0.15)) as connection:
                return [Path(row[0]) for row in connection.execute(
                    'SELECT rollout_path FROM threads WHERE archived = 0 AND updated_at >= ? '
                    'ORDER BY updated_at DESC LIMIT 32', (int(now - RECENT_SESSION_LIFETIME),)
                ) if isinstance(row[0], str)]
        except (ValueError, sqlite3.Error):
            continue
    return []


def recent_codex_sessions(root, now):
    """Find active Desktop/CLI threads even if their hooks never wrote a snapshot."""
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        return []
    root = root.resolve()
    candidates = {}
    today = datetime.fromtimestamp(now).date()
    paths = indexed_codex_paths(root, now)
    for delta in (0, 1):
        day = root / (today - timedelta(days=delta)).strftime('%Y/%m/%d')
        if day.resolve().is_relative_to(root):
            paths.extend(day.glob('rollout-*.jsonl'))
    for path in paths:
        try:
            meta = path.lstat()
            if (stat.S_ISREG(meta.st_mode) and meta.st_uid == os.getuid()
                    and 0 <= now - meta.st_mtime <= RECENT_SESSION_LIFETIME
                    and path.resolve().is_relative_to(root)):
                candidates[path] = meta.st_mtime
        except (OSError, ValueError):
            continue
    found = {}
    for path, stamp in sorted(candidates.items(), key=lambda item: item[1], reverse=True)[:32]:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                    continue
                row = json.loads(stream.readline(131072))
                lifecycle = latest_codex_lifecycle(stream, info.st_size)
            if row.get('type') != 'session_meta':
                continue
            meta = row['payload']
            identity = str(uuid.UUID(meta['id']))
            if identity in found or not matches_session(path.name, identity):
                continue
            if isinstance(meta.get('source'), dict) and 'subagent' in meta['source']:
                continue
            if '/.cache/boringnotch-agent-suggestions/' in str(meta.get('cwd', '')):
                continue
            if lifecycle and lifecycle[1] <= now+5:
                kind, started = lifecycle
                # Preserve the latest file for a thread even when that file is
                # terminal, so an older fork log cannot revive it.
                found[identity] = (kind, started, stamp, meta.get('cwd', ''))
        except (OSError, KeyError, AttributeError, TypeError, ValueError, OverflowError):
            continue
    return [(identity, kind, event_time, stamp, cwd)
            for identity, (kind, event_time, stamp, cwd) in found.items()
            if event_time <= stamp + 5 and (
                (kind == 'task_started' and now - stamp < CODEX_RUNNING_LIFETIME)
                or (kind == 'task_complete' and now - event_time < RECENT_SESSION_LIFETIME)
            )]


def enrich_progress(items, root, cache):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        return
    ids = {item['sessionID'] for item in items if item.get('source') == 'codex' and item.get('sessionID')}
    if not ids:
        return
    paths = {}
    checked_at = time.time()
    try:
        if not cache.is_symlink() and cache.stat().st_uid == os.getuid() and cache.stat().st_size < 32768:
            saved = json.loads(cache.read_text())
            if isinstance(saved, dict) and type(saved.get('checkedAt')) in (int, float) and 0 <= time.time()-saved['checkedAt'] < 20:
                checked_at = saved['checkedAt']
                saved = saved.get('paths', {})
                if not isinstance(saved, dict):
                    saved = {}
                for identity in ids:
                    candidate = saved.get(identity)
                    if isinstance(candidate, str):
                        path = Path(candidate)
                        if path.resolve().is_relative_to(root.resolve()) and matches_session(path.name, identity) and path.exists():
                            paths[identity] = path
    except (OSError, ValueError, TypeError):
        pass
    needed = ids-paths.keys()
    if needed:
        checked_at = time.time()
        deadline = time.monotonic()+0.3
        for directory, dirs, files in os.walk(root, followlinks=False):
            dirs[:] = sorted((d for d in dirs if not (Path(directory)/d).is_symlink()), reverse=True)
            for name in files:
                for identity in tuple(needed):
                    if matches_session(name, identity):
                        candidate = Path(directory)/name
                        try:
                            if identity not in paths or candidate.stat().st_mtime > paths[identity].stat().st_mtime:
                                paths[identity] = candidate
                        except OSError:
                            continue
            if time.monotonic() > deadline:
                break
    for item in items:
        path = paths.get(item.get('sessionID'))
        if path and isinstance(item.get('progress'), dict):
            lifecycle = []
            tool, steps, tokens = activity_details(path, lifecycle)
            progress = item['progress']
            observed = progress.get('observedAt')
            if lifecycle and type(observed) in (float, int) and progress.get('phase') in (
                'processing', 'running_tool', 'compacting'
            ):
                kind, timestamp = lifecycle[-1]
                if kind != 'task_started' and observed <= timestamp <= time.time() + 5:
                    progress.update(phase='finished', observedAt=timestamp, children=[])
                    item.update(title='Codex · ' + ('本轮已停止' if kind == 'turn_aborted' else '本轮回复结束'),
                                priority=50, expires=timestamp + 20)
            if tool:
                item['progress']['lastTool'] = tool
            if steps:
                item['progress']['recentTools'] = steps
            if tokens:
                item['progress']['tokenUsage'] = tokens
    temporary = cache.with_name(cache.name+'.'+uuid.uuid4().hex+'.tmp')
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(dict(checkedAt=checked_at, paths={identity:str(path) for identity,path in paths.items()}), stream)
        temporary.replace(cache)
    except OSError:
        temporary.unlink(missing_ok=True)

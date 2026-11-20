#!/usr/bin/env python3
"""Read existing AgentBridge metadata; publish a bounded, prompt-free UI snapshot.
No hooks, credentials, approval sockets or network access. Only bounded session
titles, tool names and rate-limit metadata are emitted, with no transcript content.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid
from agent_usage import collect_provider_usage, collect_usage
from agent_progress import enrich_progress, enrich_session_titles, recent_codex_sessions


def active_children(state, now):
    records = state.get('subagent_agents')
    start = state.get('subagent_turn_started_at')
    stop = state.get('subagent_root_stopped_at')
    def valid_time(value):
        return type(value) in (float, int) and math.isfinite(value)
    if (state.get('subagent_turn_had_agents') is not True or not isinstance(records, dict)
            or not valid_time(start) or (valid_time(stop) and stop >= start)):
        return 0
    return sum(1 for row in records.values()
               if isinstance(row, dict) and row.get('active') is True
               and valid_time(row.get('observed_at')) and start <= row['observed_at'] <= now + 5)


def normalize(state, now):
    if not isinstance(state, dict):
        return None
    cwd = state.get('cwd', '')
    if isinstance(cwd, str) and '/.cache/boringnotch-agent-suggestions/' in cwd:
        return None
    source, session = state.get('source'), state.get('session_id')
    stamp = state.get('observed_at')
    if not isinstance(source, str) or not isinstance(session, str):
        return None
    if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or not math.isfinite(stamp):
        return None
    age = now - stamp
    if age < -5 or age > 1200:
        return None
    event, status = state.get('event'), state.get('status')
    if event in ('SessionEnd', 'SessionExpired') or status == 'ended':
        return None
    if event == 'StopFailure':
        title, priority, lifetime = '本轮异常结束', 85, 60
    elif event == 'Stop':
        title, priority, lifetime = '本轮回复结束', 50, 20
    elif status in ('waiting_for_approval', 'waiting_for_input') and event != 'SessionStart':
        title = '已请求审批' if status == 'waiting_for_approval' else '等待你的输入'
        priority, lifetime = 90, 1200
    elif status in ('processing', 'running_tool', 'compacting'):
        title = {'running_tool': '正在调用工具', 'compacting': '正在整理上下文'}.get(status, '正在处理')
        pid = state.get('pid')
        has_pid = type(pid) is int and 0 < pid <= 2**31 - 1
        if has_pid:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return None
            except PermissionError:
                pass
        # Missing stop hooks must not leave a stale running badge indefinitely.
        priority, lifetime = 20, 300 if has_pid else 120
    else:
        return None
    if age >= lifetime:
        return None
    agent = {'claude':'Claude', 'codex':'Codex', 'gemini':'Gemini', 'codebuddy':'CodeBuddy',
             'antigravity':'Antigravity'}.get(source.lower(), source[:24])
    cwd = state.get('cwd', '')
    project = Path(cwd).name[:60] if isinstance(cwd, str) else ''
    detail = project or '本地会话'
    if priority in (20, 90) and (children := active_children(state, now)):
        detail += f' · {children} 个子 Agent 运行中'
    session_id = None
    history_id = None
    if source.lower() in ('codex', 'claude', 'gemini', 'antigravity'):
        try:
            history_id = str(uuid.UUID(session))
            if source.lower() == 'codex':
                session_id = history_id
        except (ValueError, AttributeError):
            pass
    children = []
    records = state.get('subagent_agents', {})
    start = state.get('subagent_turn_started_at')
    if isinstance(records, dict) and number_valid(start) and active_children(state, now):
        for identity, row in list(records.items())[:16]:
            if isinstance(row, dict) and row.get('active') is True and number_valid(row.get('observed_at')) and start <= row['observed_at'] <= now + 5:
                children.append(dict(id=hashlib.sha256(str(identity).encode()).hexdigest()[:12], active=True))
    phase = 'failed' if event == 'StopFailure' else 'finished' if event == 'Stop' else status
    progress = dict(phase=phase, observedAt=stamp, children=children)
    return dict(progress=progress, sessionID=session_id, conversationID=history_id,
                id=hashlib.sha256((source+'|'+session).encode()).hexdigest(), kind='agent',
                title=agent+' · '+title, detail=detail, symbol='terminal',
                priority=priority, expires=stamp+lifetime, source=source.lower())


def number_valid(value):
    return type(value) in (float, int) and math.isfinite(value)


def collect(directory, now, codex_root=None):
    result = {}
    terminal = {}
    candidates = []
    for path in (() if directory.is_symlink() else directory.glob('*.json')):
        try:
            info = path.lstat()
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_size <= 65536:
                candidates.append((info.st_mtime_ns, path))
        except OSError:
            continue
    candidates.sort(key=lambda entry: (-entry[0], entry[1].name))
    for _, path in candidates[:256]:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'r') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 65536:
                    continue
                state = json.loads(stream.read(65537))
                item = normalize(state, now)
                if not isinstance(state, dict):
                    continue
                source, session, stamp = state.get('source'), state.get('session_id'), state.get('observed_at')
                if (not isinstance(source, str) or not isinstance(session, str)
                        or type(stamp) not in (int, float) or not math.isfinite(stamp)
                        or stamp > now + 5):
                    continue
                # An end record must also win over an older duplicate activity.
                key = (source.lower(), session.lower() if source.lower() == 'codex' else session)
                if state.get('event') in ('Stop', 'StopFailure', 'SessionEnd', 'SessionExpired') or state.get('status') == 'ended':
                    terminal[key] = max(stamp, terminal.get(key, 0))
                previous = result.get(key)
                if previous is None or stamp > previous[0] or (stamp == previous[0] and item is None):
                    result[key] = (stamp, item)
        except (OSError, ValueError, TypeError):
            continue
    if codex_root is not None:
        for identity, started, stamp, cwd in recent_codex_sessions(codex_root, now):
            key = ('codex', identity)
            previous = result.get(key)
            if previous is not None and previous[0] >= started and previous[1] is not None:
                # Keep the live hook's richer status, including approvals.
                continue
            if terminal.get(key, 0) >= started:
                continue
            item = normalize(dict(source='codex', session_id=identity, cwd=cwd,
                                  observed_at=now, event='UserPromptSubmit', status='processing'), now)
            if item:
                item['progress']['observedAt'] = min(stamp, now)
                item['expires'] = stamp + 360
                result[key] = (stamp, item)
    active = [(stamp, item) for stamp, item in result.values() if item is not None]
    # Completed cards remain in local history. New running sessions get space
    # in the current snapshot even when many sessions finished together.
    return [item for _, item in sorted(active, key=lambda row: (
        row[1]['progress']['phase'] in ('finished', 'failed'), -row[1]['priority'], -row[0], row[1]['id']
    ))[:16]]



if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=Path.home()/'.multiagent-notch/session-state')
    args = parser.parse_args()
    helper = Path(__file__).with_name('activity-notify')
    now = time.time()
    usage = collect_usage(Path.home()/'.codex/sessions', now, Path.home()/'.cache/boringnotch-agent-usage.json')
    usage = collect_provider_usage(Path.home(), now, usage)
    try:
        subprocess.run([str(helper), '--usage'], input=json.dumps(usage, ensure_ascii=False).encode(), check=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as error:
        print(f'Usage delivery failed: {error}', file=sys.stderr)
    items = collect(args.source, time.time(), Path.home()/'.codex/sessions')
    enrich_session_titles(items, Path.home()/'.codex/session_index.jsonl')
    enrich_progress(items, Path.home()/'.codex/sessions', Path.home()/'.cache/boringnotch-agent-log-index.json')
    subprocess.run([str(helper)], input=json.dumps(items, ensure_ascii=False).encode(), check=True, timeout=5)

import importlib.util
from pathlib import Path
import tempfile
import json
spec = importlib.util.spec_from_file_location('bridge', Path(__file__).with_name('activity-bridge.py'))
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
request_id = 'a' * 64
base = dict(source='codex', session_id='example', cwd='/tmp/project', observed_at=1000, event='Stop', status='waiting_for_input', prompt='PRIVATE')
assert b.normalize(base, 1001)['title'] == 'Codex · 本轮回复结束'
assert b.normalize(base, 1021)['expires'] == 1020  # Retain history after the completion cue expires.
assert b.normalize(base, 1900) is None
assert b.normalize(dict(base, observed_at=float('nan')), 1001) is None
assert b.normalize(dict(base, event='SessionEnd'), 1001) is None
assert b.normalize(dict(base, event='PermissionRequest', status='waiting_for_approval'), 1001) is None
assert b.normalize(dict(base, event='PermissionRequest', status='waiting_for_approval', approval_request_id=request_id), 1001)['priority'] == 90
assert b.normalize(dict(base, event='PermissionRequest', status='waiting_for_approval', approval_request_id=request_id, pid=2147483647), 1001) is None
assert 'PRIVATE' not in json.dumps(b.normalize(base, 1001))
active = dict(base, source='antigravity', event='PreInvocation', status='processing')
assert b.normalize(active, 1119)['progress']['phase'] == 'processing'
assert b.normalize(active, 1120) is None
assert b.normalize(dict(active, pid=2147483647), 1001) is None
assert b.normalize(dict(base, event='StopFailure'), 1001)['title'].endswith('异常结束')
with tempfile.TemporaryDirectory() as d:
 p=Path(d); (p/'valid.json').write_text(json.dumps(base)); (p/'invalid.json').write_text('no')
 (p/'link.json').symlink_to(p/'valid.json')
 assert len(b.collect(p,1001)) == 1
print('PASS: stop semantics, expiry, invalid timestamps, end state, priority, privacy, malformed input and symlinks')

turn = dict(base, event='PreToolUse', status='running_tool', subagent_turn_started_at=900,
            subagent_turn_had_agents=True, subagent_agents={
              'SECRET_CHILD': {'observed_at': 955, 'active': True},
              'old': {'observed_at': 855, 'active': True},
              'finished': {'observed_at': 960, 'active': False}})
item = b.normalize(turn, 1001)
assert item['title'].endswith('正在调用工具') and item['detail'] == 'project · 1 个子 Agent 运行中'
assert 'SECRET_CHILD' not in json.dumps(item)
assert b.normalize(dict(turn,event='PreCompact',status='compacting'),1001)['title'].endswith('正在整理上下文')
assert b.normalize(dict(turn,subagent_root_stopped_at=990),1001)['detail'] == 'project'
assert b.normalize(dict(turn,event='Stop'),1001)['detail'] == 'project'
assert b.normalize(dict(turn,event='SessionExpired'),1001) is None
assert b.normalize(dict(turn,event='PermissionRequest',status='waiting_for_approval',approval_request_id=request_id),1001)['title'].endswith('已请求审批')
print('PASS: Agent Notch phase names, current-turn child count, completion boundaries and child ID privacy')

import os
with tempfile.TemporaryDirectory() as d:
    p = Path(d)
    for index in range(260):
        file = p / f'a{index:03d}.json'
        file.write_text(json.dumps(dict(base, observed_at=1, session_id=str(index))))
        os.utime(file, (1, 1))
    file = p / 'zzz-new.json'
    file.write_text(json.dumps(base))
    os.utime(file, (1000, 1000))
    assert len(b.collect(p, 1001)) == 1
    (p / 'ended.json').write_text(json.dumps(dict(base, event='SessionEnd', observed_at=1001)))
    assert b.collect(p, 1002) == []
with tempfile.TemporaryDirectory() as d:
    p = Path(d)
    for index in range(20):
        (p / f'{index}.json').write_text(json.dumps(dict(base, session_id=str(index), observed_at=1000+index)))
    urgent = dict(base, session_id='urgent', event='PermissionRequest', status='waiting_for_approval', approval_request_id=request_id, observed_at=999)
    (p / 'urgent.json').write_text(json.dumps(urgent))
    items = b.collect(p, 1020)
    assert len(items) == 16 and items[0]['priority'] == 90
    assert items[1]['id'] == b.normalize(dict(base,session_id='19',observed_at=1019),1020)['id']
    (p / 'duplicate.json').write_text(json.dumps(urgent))
    assert len(b.collect(p, 1020)) == 16
print('PASS: history saturation, newest lifecycle wins, urgent selection and deduplication')

valid_id = '01a19fc6-c4f8-7570-918f-f0132a161da5'
assert b.normalize(dict(base, session_id=valid_id), 1001)['sessionID'] == valid_id
assert b.normalize(dict(base, session_id='not-a-uuid'), 1001)['sessionID'] is None
assert b.normalize(dict(base, source='claude', session_id=valid_id), 1001)['sessionID'] is None
print('PASS: Codex session links use validated UUIDs only')

hook_spec = importlib.util.spec_from_file_location('antigravity_hook', Path(__file__).with_name('antigravity-hook.py'))
hook = importlib.util.module_from_spec(hook_spec)
hook_spec.loader.exec_module(hook)
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    other = '2cf9b94a-fd5a-40b8-8980-bab6615e37f1'
    payload = dict(conversationId=valid_id, workspacePaths=['/tmp/project'], lastUserInput='PRIVATE')
    hook.record(payload, 'PreInvocation', path, 1000)
    hook.record(dict(payload, conversationId=other), 'PreInvocation', path, 1001)
    hook.record(payload, 'Stop', path, 1002)
    rows = b.collect(path, 1003)
    assert {(r['conversationID'], r['progress']['phase']) for r in rows} == {
        (valid_id, 'finished'), (other, 'processing')
    }
    assert all(r['source'] == 'antigravity' for r in rows)
    assert 'PRIVATE' not in ''.join(f.read_text() for f in path.glob('*.json'))
print('PASS: Antigravity keeps independent task lifecycle and exports no prompt')

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    payload = dict(session_id=valid_id, cwd='/tmp/sample', prompt='PRIVATE')
    hook.record(payload, 'BeforeAgent', path, 1000, 'gemini')
    assert b.collect(path, 1001)[0]['title'] == 'Gemini · 正在处理'
    hook.record(payload, 'BeforeTool', path, 1002, 'gemini')
    assert b.collect(path, 1003)[0]['progress']['phase'] == 'running_tool'
    hook.record(payload, 'AfterAgent', path, 1004, 'gemini')
    assert b.collect(path, 1005)[0]['progress']['phase'] == 'finished'
    assert 'PRIVATE' not in next(path.glob('*.json')).read_text()
    assert b.collect(path, 1005)[0]['conversationID'] == valid_id
    hook.record(payload, 'SessionEnd', path, 1006, 'gemini')
    assert b.collect(path, 1007)[0]['progress']['phase'] == 'finished'
    hook.record(payload, 'BeforeAgent', path, 1008, 'gemini')
    hook.record(payload, 'SessionEnd', path, 1009, 'gemini')
    assert not b.collect(path, 1010)
print('PASS: Gemini CLI maps thinking, tool execution, completion and session end without prompt data')

from datetime import datetime, timezone
from uuid import uuid4
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    snapshots = root / 'snapshots'
    snapshots.mkdir()
    now = b.time.time()
    log_day = root / datetime.fromtimestamp(now).strftime('%Y/%m/%d')
    log_day.mkdir(parents=True)
    first, second, ended = [str(uuid4()) for _ in range(3)]
    def log(identity, event, *, suffix=''):
        path = log_day / f'rollout-fixture-{identity}{suffix}.jsonl'
        meta = dict(type='session_meta', payload=dict(id=identity, cwd='/tmp/example', source='vscode'))
        row = dict(type='event_msg', timestamp=datetime.fromtimestamp(now-2, timezone.utc).isoformat(),
                   payload=dict(type=event))
        path.write_text(json.dumps(meta)+'\n'+json.dumps(row)+'\n')
        os.utime(path, (now-1, now-1))
    log(first, 'task_started')
    log(second, 'task_started', suffix='_'+str(uuid4()))
    log(ended, 'turn_aborted')
    (snapshots/'first.json').write_text(json.dumps(dict(base, session_id=first, observed_at=now,
        event='PermissionRequest', status='waiting_for_approval', approval_request_id=request_id)))
    rows = b.collect(snapshots, now, root)
    assert {row['sessionID'] for row in rows} == {first, second}, rows
    assert rows[0]['progress']['phase'] == 'waiting_for_approval'
    hookless = next(row for row in rows if row['sessionID'] == second)
    assert abs(hookless['progress']['observedAt'] - (now - 2)) < 0.00001
    assert abs(hookless['expires'] - (now - 1 + b.CODEX_RUNNING_LIFETIME)) < 0.00001
    (snapshots/'second.json').write_text(json.dumps(dict(base,session_id=second,observed_at=now,event='SessionEnd')))
    assert {row['sessionID'] for row in b.collect(snapshots, now, root)} == {first}
    log(second, 'task_complete', suffix='_completed')
    os.utime(log_day / f'rollout-fixture-{second}_completed.jsonl', (now, now))
    completed_before_exit = {row['sessionID']: row['progress']['phase'] for row in b.collect(snapshots, now, root)}
    assert completed_before_exit == {first: 'waiting_for_approval', second: 'finished'}
print('PASS: two concurrent Codex threads, hookless recovery, fork file identity, approval precedence and no resurrection')

# A Desktop conversation can be resumed weeks after its log directory was created.
import sqlite3
with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    root = home / 'sessions'
    day = root / '2021/01/01'
    day.mkdir(parents=True)
    sessions = home / 'snapshots'
    sessions.mkdir()
    now = b.time.time()
    older, archived = str(uuid4()), str(uuid4())
    with sqlite3.connect(home / 'state_5.sqlite') as database:
        database.execute('CREATE TABLE threads(rollout_path TEXT, updated_at INTEGER, archived INTEGER)')
        for identity, is_archived in [(older, 0), (archived, 1)]:
            path = day / f'rollout-old-{identity}.jsonl'
            records = [
                dict(type='session_meta', payload=dict(id=identity, cwd='/tmp/reopened', source='vscode')),
                dict(type='event_msg', payload=dict(type='task_started'),
                     timestamp=datetime.fromtimestamp(now - 2, timezone.utc).isoformat())
            ]
            path.write_text(''.join(json.dumps(row) + '\n' for row in records)
                            + json.dumps(dict(type='response_item', payload=dict(type='function_call_output',
                                output='x' * 650_000))) + '\n')
            os.utime(path, (now - 1, now - 1))
            database.execute('INSERT INTO threads VALUES (?, ?, ?)', (str(path), int(now), is_archived))
    assert {row['sessionID'] for row in b.collect(sessions, now, root)} == {older}
    with (day / f'rollout-old-{older}.jsonl').open('a') as stream:
        stream.write(json.dumps(dict(type='event_msg', payload=dict(type='task_complete'),
                     timestamp=datetime.fromtimestamp(now - 0.5, timezone.utc).isoformat())) + '\n')
    os.utime(day / f'rollout-old-{older}.jsonl', (now, now))
    assert [row['progress']['phase'] for row in b.collect(sessions, now, root)] == ['finished']
    late = b.collect(sessions, now + 840, root)
    assert len(late) == 1 and late[0]['progress']['phase'] == 'finished'
    assert late[0]['expires'] < now + 840
    assert b.collect(sessions, now + 901, root) == []
print('PASS: old Codex threads are rediscovered by update time and report completion without hooks')

import json
import time
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import uuid
from agent_progress import enrich_progress, last_tool, matches_session

with tempfile.TemporaryDirectory() as directory:
    root=Path(directory); identity=str(uuid.uuid4())
    log=root/('rollout-'+identity+'.jsonl')
    log.write_text(json.dumps(dict(payload=dict(type='function_call',name='functions.exec',arguments='PRIVATE_COMMAND'))) + '\n')
    assert last_tool(log)=='functions.exec'
    item=dict(source='codex',sessionID=identity,progress=dict(phase='running_tool'))
    cache=root/'index.json'
    enrich_progress([item],root,cache)
    assert item['progress']['lastTool']=='functions.exec'
    assert matches_session('rollout-date-'+identity+'_'+str(uuid.uuid4())+'.jsonl', identity)
    assert 'PRIVATE' not in json.dumps(item)
    linked=root/'link.jsonl'; linked.symlink_to(log)
    assert last_tool(linked) is None
    log.write_text('bad json\n'+json.dumps(dict(payload=dict(type='message',name='PRIVATE_MESSAGE'))) + '\n')
    assert last_tool(log) is None
    log.write_text(json.dumps(dict(payload=dict(type='function_call',name='PRIVATE bad name',arguments='PRIVATE'))) + '\n')
    assert last_tool(log) is None
    now = time.time()
    def lifecycle_event(kind, timestamp):
        return json.dumps(dict(type='event_msg', payload=dict(type=kind),
            timestamp=datetime.fromtimestamp(timestamp, timezone.utc).isoformat()))
    log.write_text(lifecycle_event('task_started', now - 3) + '\n' +
                   lifecycle_event('turn_aborted', now - 1) + '\n')
    active = dict(source='codex', sessionID=identity, priority=20,
                  progress=dict(phase='running_tool', observedAt=now - 2, children=['old']))
    enrich_progress([active],root,cache)
    assert active['progress']['phase'] == 'finished' and active['progress']['children'] == []
    assert active['title'].endswith('本轮已停止') and abs(active['expires'] - (now + 19)) < 0.00001
    with log.open('a') as stream:
        stream.write(lifecycle_event('task_started', now) + '\n')
    current = dict(source='codex', sessionID=identity, progress=dict(phase='processing', observedAt=now))
    enrich_progress([current],root,cache)
    assert current['progress']['phase'] == 'processing'
    assert 'PRIVATE' not in cache.read_text()
print('PASS: real tool-name extraction, no arguments/messages, invalid names, symlinks and stable session lookup')

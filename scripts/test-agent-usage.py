from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
from agent_usage import collect_provider_usage, collect_usage, read_snapshot, validate_cached, window

now = 1_800_000_000
limits = dict(plan_type='plus', primary=dict(used_percent=23, window_minutes=300, resets_at=now+1000), secondary=None)
record = dict(timestamp=datetime.fromtimestamp(now, timezone.utc).isoformat(), payload=dict(type='token_count', rate_limits=limits))
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    log = root/'sample.jsonl'
    log.write_text(json.dumps(dict(payload=dict(type='message', text='PRIVATE_TRANSCRIPT'))) + '\n' + json.dumps(record) + '\n')
    snapshot = read_snapshot(log, now)
    assert snapshot['primary']['usedPercent'] == 23
    assert snapshot['planType'] == 'plus'
    assert 'PRIVATE' not in json.dumps(snapshot)
    cache = root/'numeric-cache.json'
    assert collect_usage(root, now, cache) == snapshot
    log.write_text('bad json\n')
    assert collect_usage(root, now+2, cache) == snapshot
    assert collect_usage(root, now+6, cache) is None
    log.write_text(json.dumps(record)+'\n')
    linked = root/'linked.jsonl'; linked.symlink_to(log)
    assert read_snapshot(linked, now) is None
    stale = dict(record, timestamp=datetime.fromtimestamp(now-90000, timezone.utc).isoformat())
    log.write_text(json.dumps(stale)+'\n')
    assert read_snapshot(log, now) is None
    assert read_snapshot(log, now-90000) is not None
    cache.write_text('[]')
    assert collect_usage(root, now, cache) is None
    cache.write_text(json.dumps(dict(checkedAt=now, snapshot={'PRIVATE_SECRET': 'PRIVATE'})))
    assert collect_usage(root, now, cache) is None
    old = root/'touched-later.jsonl'
    old.write_text(json.dumps(dict(record, timestamp=datetime.fromtimestamp(now-10, timezone.utc).isoformat()))+'\n')
    log.write_text(json.dumps(record)+'\n')
    import os
    os.utime(log, (now, now))
    os.utime(old, (now+5, now+5))
    assert collect_usage(root, now) == snapshot
assert window(dict(used_percent=True, window_minutes=300, resets_at=now)) is None
assert window(dict(used_percent=float('nan'), window_minutes=300, resets_at=now)) is None
assert window(dict(used_percent=101, window_minutes=300, resets_at=now)) is None
assert window(dict(used_percent=23, window_minutes=0, resets_at=now)) is None
assert validate_cached(dict(updatedAt=now, primary='PRIVATE'), now) is None
assert validate_cached(dict(snapshot, updatedAt=now+100), now) is None
print('PASS: local quota extraction, numeric-only output, corrupt/stale cache, symlinks, invalid numbers and TTL')


with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    widget = home/'Library/Group Containers/Y5PE65HELJ.com.steipete.codexbar/widget-snapshot.json'
    widget.parent.mkdir(parents=True)
    stamp = datetime.fromtimestamp(now, timezone.utc).isoformat()
    reset = datetime.fromtimestamp(now + 86400, timezone.utc).isoformat()
    daily = dict(usedPercent=33, windowMinutes=1440, resetsAt=reset)
    widget.write_text(json.dumps(dict(entries=[
        dict(provider='claude', updatedAt=stamp, primary=dict(usedPercent=45, windowMinutes=10080, resetsAt=reset),
             secondary=dict(usedPercent=85, windowMinutes=300, resetsAt=reset), quotaOwnerKey='PRIVATE_ACCOUNT'),
        dict(provider='gemini', updatedAt=stamp, usageRows=[dict(title='Gemini Pro', window=daily),
                                                           dict(title='Gemini Flash', percentLeft=67)]),
        dict(provider='openai', updatedAt=stamp, providerCost=dict(used=7.5, limit=20, currencyCode='USD', updatedAt=stamp)),
        dict(provider='fake', updatedAt=stamp, primary=dict(usedPercent=True)),
    ])))
    providers = {entry['id']: entry for entry in collect_provider_usage(home, now, snapshot)}
    assert set(providers) == {'codex', 'claude', 'gemini', 'openai'}
    assert providers['claude']['windows'][0]['windowMinutes'] == 10080
    assert providers['claude']['windows'][1]['windowMinutes'] == 300
    assert providers['gemini']['windows'][0]['label'] == 'Gemini Pro'
    assert providers['gemini']['windows'][1]['label'] == 'Gemini Flash'
    assert providers['gemini']['windows'][1]['usedPercent'] == 33
    assert providers['openai']['windows'] == [] and providers['openai']['billing']['used'] == 7.5
    assert 'PRIVATE' not in json.dumps(providers)
    assert 'billing' not in providers['codex']
    stale = {entry['id']: entry for entry in collect_provider_usage(home, now + 86401, None)}
    assert 'openai' not in stale
    assert not collect_provider_usage(home/'missing', now, None)
print('PASS: CodexBar multi-provider widget input, API spend, alternate quota periods, stale billing and identity exclusion')

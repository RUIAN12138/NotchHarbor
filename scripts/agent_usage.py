"""Agent Notch's bounded local token_count.rate_limits reader, adapted for the
existing read-only bridge. Apache-2.0 source: Services/Usage/UsageLimitMonitor.swift.
No credential files, network requests, prompts or transcript content are emitted.
"""
from datetime import datetime
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import time
import uuid

USAGE_CACHE_SECONDS = 6
CLI_POLL_CACHE_SECONDS = 75
WIDGET_SNAPSHOT = Path('Library/Group Containers/Y5PE65HELJ.com.steipete.codexbar/widget-snapshot.json')


def number(value):
    return value if type(value) in (int, float) and math.isfinite(value) else None


def window(value):
    if not isinstance(value, dict):
        return None
    used, minutes, reset = (number(value.get(key)) for key in ('used_percent', 'window_minutes', 'resets_at'))
    if used is None or minutes is None or reset is None or not 0 <= used <= 100 or not 1 <= minutes <= 527040 or reset <= 0:
        return None
    return dict(usedPercent=used, windowMinutes=int(minutes), resetsAt=reset)


def read_snapshot(path, now):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                return None
            offset = max(0, info.st_size - 1048576)
            stream.seek(offset)
            lines = stream.read(1048576).splitlines()
            if offset and lines:
                lines.pop(0)
            for line in reversed(lines):
                if b'"rate_limits"' not in line:
                    continue
                try:
                    record = json.loads(line)
                    payload = record.get('payload', {})
                    if payload.get('type') != 'token_count':
                        continue
                    limits = payload.get('rate_limits')
                    if not isinstance(limits, dict):
                        continue
                    primary, secondary = window(limits.get('primary')), window(limits.get('secondary'))
                    if primary is None and secondary is None:
                        continue
                    timestamp = record.get('timestamp')
                    updated = datetime.fromisoformat(timestamp.replace('Z', '+00:00')).timestamp() if isinstance(timestamp, str) else info.st_mtime
                    if not now - 86400 <= updated <= now + 5:
                        continue
                    plan = limits.get('plan_type')
                    plan = plan[:32] if isinstance(plan, str) and all(c.isalnum() or c in '_- ' for c in plan) else None
                    return dict(planType=plan, primary=primary, secondary=secondary, updatedAt=updated)
                except (ValueError, TypeError, AttributeError, OverflowError):
                    continue
    except OSError:
        pass
    return None


def validate_cached(value, now):
    if not isinstance(value, dict):
        return None
    updated = number(value.get('updatedAt'))
    if updated is None or not now - 86400 <= updated <= now + 5:
        return None
    result = dict(updatedAt=updated)
    for key in ('primary', 'secondary'):
        raw = value.get(key)
        result[key] = window(dict(used_percent=raw.get('usedPercent'), window_minutes=raw.get('windowMinutes'),
                                  resets_at=raw.get('resetsAt'))) if isinstance(raw, dict) else None
    if result['primary'] is None and result['secondary'] is None:
        return None
    plan = value.get('planType')
    result['planType'] = plan[:32] if isinstance(plan, str) and all(c.isalnum() or c in '_- ' for c in plan) else None
    return result


def collect_usage(root, now, cache=None):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        return None
    if cache is not None:
        try:
            if not cache.is_symlink() and cache.stat().st_uid == os.getuid() and cache.stat().st_size < 16384:
                stored = json.loads(cache.read_text())
                if not isinstance(stored, dict):
                    stored = {}
                stamp = number(stored.get('checkedAt'))
                if stamp is not None and 0 <= now - stamp < USAGE_CACHE_SECONDS:
                    return validate_cached(stored.get('snapshot'), now)
        except (OSError, ValueError, TypeError):
            pass
    candidates = []
    deadline = time.monotonic() + 0.3
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted((d for d in dirs if not d.startswith('.') and not (Path(directory) / d).is_symlink()), reverse=True)
        for name in files:
            if not name.endswith('.jsonl'):
                continue
            path = Path(directory) / name
            try:
                info = path.lstat()
                if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid():
                    candidates.append((info.st_mtime, path))
            except OSError:
                pass
        if time.monotonic() > deadline or len(candidates) >= 4096:
            break
    snapshot = None
    for _, path in sorted(candidates, reverse=True)[:8]:
        candidate = read_snapshot(path, now)
        if candidate is not None and (snapshot is None or candidate['updatedAt'] > snapshot['updatedAt']):
            snapshot = candidate
    if cache is not None:
        temporary = cache.with_name(cache.name + '.' + uuid.uuid4().hex + '.tmp')
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, 'w') as stream:
                json.dump(dict(checkedAt=now, snapshot=snapshot), stream)
            temporary.replace(cache)
        except OSError:
            temporary.unlink(missing_ok=True)
    return snapshot


def snapshot_time(value):
    if not isinstance(value, str):
        return None
    try:
        date = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return date.timestamp() if date.tzinfo is not None else None
    except (ValueError, OverflowError, OSError):
        return None


def clean_label(value, limit):
    if isinstance(value, str):
        return ''.join(c for c in value if c.isprintable()).strip()[:limit] or None
    return None


def widget_window(raw, now, label=None):
    if not isinstance(raw, dict):
        return None
    used = number(raw.get('usedPercent'))
    minutes = number(raw.get('windowMinutes'))
    reset = snapshot_time(raw.get('resetsAt'))
    if used is None:
        return None
    # CodexBar uses 1970-01-01T00:00:00Z (epoch <= 86400) when a rolling quota pool is untouched (0% used).
    valid_reset = reset if reset is not None and 86400 < reset < now + 366 * 86400 else None
    return dict(usedPercent=max(0, min(100, used)),
                windowMinutes=int(minutes) if minutes is not None and 1 <= minutes <= 527040 else None,
                resetsAt=valid_reset,
                label=clean_label(label, 48))


def widget_provider(entry, now):
    if not isinstance(entry, dict) or entry.get('error'):
        return None
    provider = entry.get('provider')
    usage_body = entry.get('usage') if isinstance(entry.get('usage'), dict) else entry
    stamp = snapshot_time(usage_body.get('updatedAt') or entry.get('updatedAt'))
    if not isinstance(provider, str) or not 1 <= len(provider) <= 64 or not all(
        c in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in provider
    ) or stamp is None or stamp > now + 5:
        return None
    rate_labels = entry.get('rateWindowLabels') if isinstance(entry.get('rateWindowLabels'), dict) else {}
    extra_rows = (usage_body.get('extraRateWindows')
                  if isinstance(usage_body.get('extraRateWindows'), list)
                  else entry.get('extraRateWindows'))
    slot_map = {}
    windows = []
    if isinstance(extra_rows, list) and extra_rows:
        for row in extra_rows[:8]:
            if not isinstance(row, dict):
                continue
            parsed = widget_window(row.get('window'), now, row.get('title'))
            if parsed is not None:
                windows.append(parsed)
    if not windows:
        for key in ('primary', 'secondary', 'tertiary'):
            w = widget_window(usage_body.get(key), now, rate_labels.get(key))
            if w is not None:
                slot_map[key] = w
                windows.append(w)
    rows = usage_body.get('usageRows') if isinstance(usage_body.get('usageRows'), list) else entry.get('usageRows')
    if isinstance(rows, list):
        for row in rows[:8]:
            if not isinstance(row, dict):
                continue
            row_id = row.get('id')
            row_label = row.get('title')
            parsed = widget_window(row.get('window'), now, row_label)
            if parsed is None:
                percent_left = number(row.get('percentLeft'))
                label = clean_label(row_label, 48)
                if percent_left is not None and 0 <= percent_left <= 100 and label:
                    parsed = widget_window({'usedPercent': 100 - percent_left}, now, label)
            if parsed is None:
                continue
            if isinstance(row_id, str) and row_id in slot_map:
                target_slot = slot_map[row_id]
                if target_slot['label'] is None and parsed['label'] is not None:
                    target_slot['label'] = parsed['label']
                continue
            # Upgrade an unlabeled primary/secondary slot when a named row matches its metrics,
            # so Gemini vs Claude/GPT model pool labels from Antigravity/CodexBar survive intact.
            upgraded = False
            for old in windows:
                same_full = all(old[k] == parsed[k] for k in ('usedPercent', 'windowMinutes', 'resetsAt'))
                same_pct_only = (parsed['windowMinutes'] is None and parsed['resetsAt'] is None
                                 and abs(old['usedPercent'] - parsed['usedPercent']) < 0.01)
                if (same_full or same_pct_only) and old['label'] is None and parsed['label'] is not None:
                    old['label'] = parsed['label']
                    upgraded = True
                    break
                if same_full and (old['label'] == parsed['label'] or parsed['label'] is None):
                    upgraded = True
                    break
            if not upgraded:
                windows.append(parsed)
    result = dict(id=provider, updatedAt=stamp, windows=windows[:8])
    billing = entry.get('providerCost')
    if isinstance(billing, dict):
        billed_at = snapshot_time(billing.get('updatedAt'))
        currency = billing.get('currencyCode')
        if billed_at is not None and now - 86400 <= billed_at <= now + 5 and isinstance(currency, str) and (
            1 <= len(currency) <= 12 and currency.isascii() and currency.isalpha()
        ):
            amounts = {key: number(billing.get(key)) for key in ('used', 'limit', 'balance')}
            balance_at = snapshot_time(billing.get('balanceUpdatedAt'))
            if balance_at is not None and not now - 86400 <= balance_at <= now + 5:
                amounts['balance'] = None
            if any(value is not None and abs(value) <= 1e12 for value in amounts.values()):
                result['billing'] = dict(currencyCode=currency, **{
                    key: value for key, value in amounts.items() if value is not None and abs(value) <= 1e12
                })
    token_usage = entry.get('tokenUsage')
    if isinstance(token_usage, dict):
        counted_at = snapshot_time(token_usage.get('updatedAt'))
        if counted_at is not None and now - 86400 <= counted_at <= now + 5:
            tokens = token_usage.get('last30DaysTokens')
            if type(tokens) is int and 0 <= tokens <= 10**14:
                result['localTokens30Days'] = tokens
    return result if windows or 'billing' in result or 'localTokens30Days' in result else None


def _has_dual_pool_labels(windows):
    labels = ' '.join((w.get('label') or '').lower() for w in windows if isinstance(w, dict))
    return ('claude' in labels or 'gpt' in labels or '3p' in labels) and ('gemini' in labels or len(windows) >= 2)


def _read_local_override_usage(home, now):
    path = home / '.multiagent-notch/provider-usage.json'
    results = []
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 262_144:
                return results
            payload = json.loads(stream.read(262_145))
            items = payload.get('entries') if isinstance(payload, dict) else payload
            if isinstance(items, list):
                for entry in items[:16]:
                    parsed = widget_provider(entry, now)
                    if parsed is not None:
                        results.append(parsed)
    except (OSError, ValueError, TypeError, RecursionError):
        pass
    return results


def _system_proxy_env():
    env = dict(os.environ)
    if any(env.get(k) for k in ('https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY')):
        return env
    try:
        out = subprocess.check_output(['/usr/sbin/scutil', '--proxy'], stderr=subprocess.DEVNULL,
                                      text=True, timeout=1.5)
        kv = dict(re.findall(r'^\s*([A-Za-z0-9]+)\s*:\s*(\S+)\s*$', out, flags=re.M))
        if kv.get('HTTPSEnable') == '1' and kv.get('HTTPSProxy') and kv.get('HTTPSPort'):
            proxy = f"http://{kv['HTTPSProxy']}:{kv['HTTPSPort']}"
            env['https_proxy'] = env['HTTPS_PROXY'] = proxy
        if kv.get('HTTPEnable') == '1' and kv.get('HTTPProxy') and kv.get('HTTPPort'):
            proxy = f"http://{kv['HTTPProxy']}:{kv['HTTPPort']}"
            env['http_proxy'] = env['HTTP_PROXY'] = proxy
        if kv.get('SOCKSEnable') == '1' and kv.get('SOCKSProxy') and kv.get('SOCKSPort'):
            socks = f"socks5h://{kv['SOCKSProxy']}:{kv['SOCKSPort']}"
            env.setdefault('all_proxy', socks)
            env.setdefault('ALL_PROXY', socks)
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return env


def _poll_codexbar_gemini(home, now):
    if os.environ.get('NOTCH_HARBOR_DISABLE_CLI_POLL') == '1':
        return []
    real_home = Path.home()
    try:
        if home.resolve() != real_home.resolve():
            return []
    except OSError:
        return []
    cache_path = home / '.multiagent-notch/codexbar-gemini-cache.json'
    prior_items = []
    try:
        if not cache_path.is_symlink() and cache_path.is_file() and cache_path.stat().st_size < 65536:
            cached = json.loads(cache_path.read_text())
            if isinstance(cached, dict):
                raw_items = cached.get('items')
                if isinstance(raw_items, list) and raw_items:
                    prior_items = raw_items[:4]
                checked = number(cached.get('checkedAt'))
                ttl = CLI_POLL_CACHE_SECONDS if prior_items else 15
                if checked is not None and 0 <= now - checked < ttl:
                    return [p for item in prior_items if (p := widget_provider(item, now)) is not None]
    except (OSError, ValueError, TypeError):
        pass

    cli_candidates = [
        Path('/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI'),
        home / 'Applications/CodexBar.app/Contents/Helpers/CodexBarCLI',
        Path('/opt/homebrew/bin/codexbar'),
        Path('/usr/local/bin/codexbar'),
        home / 'bin/codexbar',
    ]
    cli = next((c for c in cli_candidates if c.is_file() and os.access(c, os.X_OK)), None)
    if cli is None:
        return []

    env = _system_proxy_env()
    collected_raw = []
    for provider in ('antigravity', 'gemini'):
        try:
            proc = subprocess.run(
                [str(cli), 'usage', '--provider', provider, '--web-timeout', '6', '--json'],
                capture_output=True, text=True, env=env, timeout=18, stdin=subprocess.DEVNULL
            )
            if proc.stdout:
                parsed_json = json.loads(proc.stdout)
                if isinstance(parsed_json, list):
                    for item in parsed_json[:2]:
                        if isinstance(item, dict) and not item.get('error'):
                            collected_raw.append(item)
            if collected_raw:
                break
        except (OSError, subprocess.SubprocessError, ValueError, TypeError):
            continue

    fresh_now = max(now, time.time())
    effective_items = collected_raw if collected_raw else prior_items
    try:
        cache_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        tmp = cache_path.with_name(cache_path.name + '.' + uuid.uuid4().hex + '.tmp')
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(dict(checkedAt=fresh_now, items=effective_items), stream)
        tmp.replace(cache_path)
    except OSError:
        pass
    return [p for item in effective_items if (p := widget_provider(item, fresh_now)) is not None]


def collect_provider_usage(home, now, codex_snapshot):
    # Reuse the public widget snapshot published by installed CodexBar. The bridge reads
    # the same-user file and forwards only quota, amounts and aggregate token counts.
    path = home / WIDGET_SNAPSHOT
    entries = {}
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(fd)
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_size <= 2_097_152:
                snapshot = json.loads(stream.read(2_097_153))
                if isinstance(snapshot, dict) and isinstance(snapshot.get('entries'), list):
                    for entry in snapshot['entries'][:32]:
                        parsed = widget_provider(entry, now)
                        if parsed is not None and (parsed['id'] not in entries or
                                parsed['updatedAt'] > entries[parsed['id']]['updatedAt']):
                            entries[parsed['id']] = parsed
    except (OSError, ValueError, RecursionError):
        pass

    for parsed in _read_local_override_usage(home, now):
        pid = parsed['id']
        if pid not in entries or parsed['updatedAt'] >= entries[pid]['updatedAt']:
            entries[pid] = parsed

    if 'antigravity' not in entries and 'gemini' not in entries:
        for parsed in _poll_codexbar_gemini(home, now):
            pid = parsed['id']
            if pid not in entries or parsed['updatedAt'] >= entries[pid]['updatedAt']:
                entries[pid] = parsed

    # Unify Antigravity dual-pool quota (Gemini Models + Claude/GPT Models) into 'gemini'
    # when 'antigravity' provides dual-pool windows or 'gemini' is absent.
    anti = entries.get('antigravity')
    gem = entries.get('gemini')
    if anti is not None:
        if gem is None:
            entries['gemini'] = dict(anti, id='gemini')
            del entries['antigravity']
        elif _has_dual_pool_labels(anti.get('windows', [])) and not _has_dual_pool_labels(gem.get('windows', [])):
            entries['gemini'] = dict(anti, id='gemini')
            del entries['antigravity']

    if codex_snapshot is not None:
        existing = entries.get('codex', {})
        if not existing.get('windows') or codex_snapshot['updatedAt'] > existing['updatedAt']:
            entries['codex'] = dict(existing, id='codex', updatedAt=codex_snapshot['updatedAt'],
                                    windows=[w for key in ('primary', 'secondary')
                                             if (w := codex_snapshot.get(key)) is not None])
    return list(entries.values())

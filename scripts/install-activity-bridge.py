#!/usr/bin/env python3
"""Install only this project's read-only launchd watcher. Never edits Agent hooks."""
import plistlib
import subprocess
import sys
import os
import time
from pathlib import Path
from agent_usage import WIDGET_SNAPSHOT
label='local.boringnotch.activity-bridge'
path=Path.home()/'Library/LaunchAgents'/f'{label}.plist'
root=Path(__file__).resolve().parent
payload={'Label':label,'ProgramArguments':[sys.executable,str(root/'activity-bridge.py')],
         'WatchPaths':[str(Path.home()/'.multiagent-notch/session-state')],
         'RunAtLoad':True,'StartInterval':8,'ThrottleInterval':2,'ProcessType':'Background'}
widget_directory = (Path.home() / WIDGET_SNAPSHOT).parent
if widget_directory.is_dir():
    # Atomic replacements change the directory entry, not the original inode.
    payload['WatchPaths'].append(str(widget_directory))
if path.exists():
    old=plistlib.loads(path.read_bytes())
    if old.get('Label') != label or old.get('ProgramArguments',[])[-1:] != [str(root/'activity-bridge.py')]:
        raise SystemExit('Existing configuration differs; review it before replacing.')
subprocess.run(['xcrun','swiftc',str(root/'activity-notify.swift'),'-o',str(root/'activity-notify')],check=True)
path.parent.mkdir(exist_ok=True)
path.write_bytes(plistlib.dumps(payload))
subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}/{label}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
for delay in (1, 2, 3):
    time.sleep(delay)
    result = subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(path)], capture_output=True)
    if result.returncode == 0:
        break
else:
    raise SystemExit(result.stderr.decode(errors='replace').strip())
print(path)

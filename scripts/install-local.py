import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import sys

if len(sys.argv) != 3:
    raise SystemExit("Usage: install-local.py BUILT_APP BACKUP_DIRECTORY")
build = Path(sys.argv[1]).resolve(strict=True)
artifact = Path(sys.argv[2]).resolve()
artifact.mkdir(parents=True, exist_ok=True)
old = Path('/Applications/Notch Harbor.app')
new = Path('/Applications/Notch Harbor.app')
plist = Path.home() / 'Library/LaunchAgents/local.boringnotch.keepalive.plist'
domain = f'gui/{os.getuid()}'
service = f'{domain}/local.boringnotch.keepalive'
lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def bootstrap():
    for delay in (1, 2, 3):
        time.sleep(delay)
        result = subprocess.run(['launchctl', 'bootstrap', domain, str(plist)], capture_output=True)
        if result.returncode == 0:
            return
    result.check_returncode()

def info(app):
    return plistlib.loads((app/'Contents/Info.plist').read_bytes())

def requirement(app):
    output = subprocess.check_output(['codesign', '-dr', '-', str(app)], stderr=subprocess.STDOUT, text=True)
    return next(line for line in output.splitlines() if line.startswith('designated =>'))

def running_pids(app, executable):
    prefix = str(app/'Contents/MacOS'/executable)
    matches = []
    for line in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines():
        pid, command = line.strip().split(maxsplit=1)
        if command == prefix or command.startswith(prefix + ' '):
            matches.append(int(pid))
    return matches

assert old.is_dir() and build != old
checker_source = Path(__file__).with_name("check-local-window.swift")
with tempfile.TemporaryDirectory(prefix="harbor-runtime-check-") as check_dir:
    checker = Path(check_dir) / "check-local-window"
    run("xcrun", "swiftc", str(checker_source), "-o", str(checker))
    (artifact/"check-local-window").write_bytes(checker.read_bytes())
checker = artifact/"check-local-window"
checker.chmod(0o700)
settings = info(build)
assert all(settings[k] == 'Notch Harbor' for k in ('CFBundleName', 'CFBundleDisplayName')), settings.get('CFBundleName')
assert settings['CFBundleIdentifier'] == info(old)['CFBundleIdentifier']
assert requirement(build) == requirement(old)
assert not settings.get('SUFeedURL')
run('codesign', '--verify', '--deep', '--strict', str(build))
executable = settings['CFBundleExecutable']
original_plist = plist.read_bytes()
(artifact/'keepalive-before.plist').write_bytes(original_plist)
updated = plistlib.loads(original_plist)
updated['ProgramArguments'] = ['/usr/bin/open', '-g', '-a', str(new), '--args', '--background-login']
updated.pop('KeepAlive', None)
backup = artifact/'Before-Notch-Harbor.zip'
if backup.exists():
    raise SystemExit(f"Backup already exists: {backup}")
run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(old), str(backup))
run('unzip', '-tq', str(backup), stdout=subprocess.DEVNULL)

with tempfile.TemporaryDirectory(dir='/Applications', prefix='.notch-harbor-') as temp:
    work = Path(temp)
    candidate = work/new.name
    previous = work/"previous.app"
    run('ditto', str(build), str(candidate))
    run('codesign', '--verify', '--deep', '--strict', str(candidate))
    subprocess.run(['launchctl', 'bootout', service], capture_output=True)
    for pid in running_pids(new, executable):
        os.kill(pid, 15)
    for _ in range(20):
        if not running_pids(new, executable):
            break
        time.sleep(.15)
    for pid in running_pids(new, executable):
        os.kill(pid, 9)
    try:
        run(lsregister, '-u', str(old), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        old.rename(previous)
        candidate.rename(new)
        plist.write_bytes(plistlib.dumps(updated))
        run(lsregister, '-f', str(new), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Launch the replacement as a user open. Register the login job after
        # the visible launch, so its RunAtLoad does not own the first open.
        run('/usr/bin/open', str(new))
        pid = int(subprocess.check_output([str(checker), str(new), '--window'], text=True))
        bootstrap()
        reopened = int(subprocess.check_output([str(checker), str(new), '--window'], text=True))
        assert reopened == pid
        assert running_pids(new, executable) == [pid]
        run('codesign', '--verify', '--deep', '--strict', str(new))
        expected = hashlib.sha256((build/'Contents/MacOS'/executable).read_bytes()).hexdigest()
        assert expected == hashlib.sha256((new/'Contents/MacOS'/executable).read_bytes()).hexdigest()
        assert not (new/"Contents/MacOS/boringNotch").exists()
    except BaseException:
        subprocess.run(['launchctl', 'bootout', service], capture_output=True)
        if previous.exists() and new.exists():
            for candidate_pid in running_pids(new, executable):
                try:
                    os.kill(candidate_pid, 15)
                except ProcessLookupError:
                    pass
            subprocess.run([lsregister, '-u', str(new)], capture_output=True)
            shutil.rmtree(new)
        if previous.exists():
            previous.rename(old)
        plist.write_bytes(original_plist)
        run(lsregister, '-f', str(old), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        bootstrap()
        raise
subprocess.run([lsregister, '-u', str(build)], capture_output=True)
shutil.rmtree(build)
print(f'Installed and running: {new} (PID {pid})')
print(f'Backup: {backup}')

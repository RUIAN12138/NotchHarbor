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
legacy_identity = 'theboringteam.boringnotch'
harbor_identity = 'com.notchharbor.app'
old_label = 'local.boringnotch.keepalive'
new_label = harbor_identity + '.keepalive'
jobs = Path.home() / 'Library/LaunchAgents'
old_plist = jobs / (old_label + '.plist')
plist = jobs / (new_label + '.plist')
domain = f'gui/{os.getuid()}'
service = f'{domain}/{new_label}'
old_service = f'{domain}/{old_label}'
lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def bootstrap(launch_plist):
    for delay in (1, 2, 3):
        time.sleep(delay)
        result = subprocess.run(['launchctl', 'bootstrap', domain, str(launch_plist)], capture_output=True)
        if result.returncode == 0:
            return
    result.check_returncode()

def info(app):
    return plistlib.loads((app/'Contents/Info.plist').read_bytes())

def requirement(app):
    output = subprocess.check_output(['codesign', '-dr', '-', str(app)], stderr=subprocess.STDOUT, text=True)
    return next(line for line in output.splitlines() if line.startswith('designated =>'))

def running_pids(app, executable):
    prefix = os.fsencode(app/'Contents/MacOS'/executable)
    matches = []
    for line in subprocess.check_output(['ps','-axo','pid=,command=']).splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) != 2:
            continue
        pid, command = fields
        if command == prefix or command.startswith(prefix + b' '):
            matches.append(int(pid))
    return matches

def migrate_container():
    containers = Path.home() / 'Library/Containers'
    old_data = containers / legacy_identity / 'Data/Library'
    new_data = containers / harbor_identity / 'Data/Library'
    # macOS creates the new container metadata for the actual signed app.
    run('/usr/bin/open', '-g', '-W', '-a', str(new), '--args', '--prepare-identity-migration', timeout=20)
    if not new_data.is_dir():
        raise RuntimeError("macOS did not create the new Notch Harbor data container")
    backup_data = artifact / 'legacy-container-data'
    backup_data.mkdir(mode=0o700)
    preferences = old_data / 'Preferences' / (legacy_identity + '.plist')
    new_preferences = new_data / 'Preferences' / (harbor_identity + '.plist')
    if preferences.is_file():
        backup_preferences = backup_data / preferences.name
        shutil.copy2(preferences, backup_preferences)
        previous = plistlib.loads(preferences.read_bytes())
        current = plistlib.loads(new_preferences.read_bytes()) if new_preferences.is_file() else {}
        current = {**previous, **current}
        new_preferences.parent.mkdir(exist_ok=True)
        if new_preferences.exists():
            shutil.copy2(new_preferences, backup_data / new_preferences.name)
        with tempfile.NamedTemporaryFile(dir=new_preferences.parent, delete=False) as handle:
            handle.write(plistlib.dumps(current, fmt=plistlib.FMT_BINARY))
        os.replace(handle.name, new_preferences)
    for name in ('ClipboardHistory', 'boringNotch/Shelf', 'UnifiedActivities'):
        source = old_data / 'Application Support' / name
        if not source.is_dir():
            continue
        destination = new_data / 'Application Support' / name
        copy = backup_data / 'Application Support' / name
        copy.parent.mkdir(parents=True, exist_ok=True)
        run('ditto', str(source), str(copy))
        if not destination.exists():
            destination.parent.mkdir(parents=True, exist_ok=True)
            run('ditto', str(copy), str(destination))


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
old_identity = info(old)['CFBundleIdentifier']
assert old_identity in (legacy_identity, harbor_identity)
assert settings['CFBundleIdentifier'] == harbor_identity
assert requirement(build) == requirement(old).replace('"' + old_identity + '"', '"' + harbor_identity + '"')
assert not settings.get('SUFeedURL')
run('codesign', '--verify', '--deep', '--strict', str(build))
executable = settings['CFBundleExecutable']
previous_jobs = {path: path.read_bytes() for path in (old_plist, plist) if path.is_file()}
for path, original in previous_jobs.items():
    (artifact / path.name).write_bytes(original)
updated = plistlib.loads(previous_jobs.get(plist, previous_jobs.get(old_plist, plistlib.dumps({'RunAtLoad': True}))))
updated['Label'] = new_label
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
    for job in (service, old_service):
        subprocess.run(['launchctl', 'bootout', job], capture_output=True)
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
        run(lsregister, '-f', str(new), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if old_identity == legacy_identity:
            migrate_container()
        plist.write_bytes(plistlib.dumps(updated))
        # Check ordinary startup, then the login job and a repeated open.
        for _ in range(4):
            launch = subprocess.run(['/usr/bin/open', str(new)], capture_output=True)
            if launch.returncode == 0:
                break
            time.sleep(1)
        launch.check_returncode()
        pid = int(subprocess.check_output([str(checker), str(new), '--quiet-launch'], text=True))
        bootstrap(plist)
        run('/usr/bin/open', str(new))
        reopened = int(subprocess.check_output([str(checker), str(new), '--quiet-launch'], text=True))
        assert reopened == pid
        assert running_pids(new, executable) == [pid]
        run('codesign', '--verify', '--deep', '--strict', str(new))
        expected = hashlib.sha256((build/'Contents/MacOS'/executable).read_bytes()).hexdigest()
        assert expected == hashlib.sha256((new/'Contents/MacOS'/executable).read_bytes()).hexdigest()
        assert not (new/"Contents/MacOS/boringNotch").exists()
        if old_plist in previous_jobs:
            old_plist.unlink()
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
        if plist not in previous_jobs:
            plist.unlink(missing_ok=True)
        for path, original in previous_jobs.items():
            path.write_bytes(original)
        run(lsregister, '-f', str(old), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        preferred = plist if old_identity == harbor_identity else old_plist
        if preferred in previous_jobs:
            bootstrap(preferred)
        else:
            run('/usr/bin/open', '-g', str(old))
        raise
subprocess.run([lsregister, '-u', str(build)], capture_output=True)
if not (os.statvfs(build).f_flag & os.ST_RDONLY):
    shutil.rmtree(build)
print(f'Installed and running: {new} (PID {pid})')
print(f'Backup: {backup}')

#!/bin/bash
set -euo pipefail

app=${1:?Pass the path to the built Notch Harbor.app}
output=${2:?Pass an output directory}
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
arch=$(lipo -archs "$app/Contents/MacOS/NotchHarbor" | tr ' ' '-')
codesign --verify --deep --strict "$app"
mkdir -p "$output"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/root" "$stage/image"
ditto "$app" "$stage/root/Notch Harbor.app"
pkgbuild --analyze --root "$stage/root" "$stage/components.plist"
# Prevent Installer from selecting an older build in a checkout or mounted image.
/usr/bin/python3 - "$stage/components.plist" <<'PY'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
components = plistlib.loads(path.read_bytes())
for component in components:
    component["BundleIsRelocatable"] = False
path.write_bytes(plistlib.dumps(components))
PY
pkgbuild --root "$stage/root" --component-plist "$stage/components.plist" \
    --identifier com.notchharbor.app.installer --version "$version" --install-location /Applications \
    "$stage/image/Install Notch Harbor.pkg"
mv "$stage/root/Notch Harbor.app" "$stage/image/"
ln -s /Applications "$stage/image/Applications"
hdiutil create -fs HFS+ -format UDZO -volname 'Notch Harbor' -srcfolder "$stage/image" \
    "$output/Notch-Harbor-$version-$arch.dmg"

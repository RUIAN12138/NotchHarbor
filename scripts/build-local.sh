#!/bin/zsh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${NOTCH_HARBOR_BUILD_DIR:-$repo_dir/.build}"
package_dir="${NOTCH_HARBOR_PACKAGES_DIR:-$build_dir/swift-packages}"
package_cache_dir="$build_dir/swiftpm-cache"
sign_identity="${NOTCH_HARBOR_SIGNING_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  sign_identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
  sign_identity="${sign_identity:--}"
fi
folia_source="$repo_dir/THIRD_PARTY/Folia"
folia_deps="$build_dir/folia"

mkdir -p "$folia_deps" "$package_cache_dir"
cp "$folia_source/package.json" "$folia_source/package-lock.json" "$folia_deps/"
(cd "$folia_deps" && npm ci --prefer-offline --no-audit --no-fund)

skip_updates_flag=()
if [[ -f "$package_dir/checkouts/swift-syntax/Package.swift" && -f "$package_dir/checkouts/Sparkle/Package.swift" ]]; then
  skip_updates_flag=(-skipPackageUpdates)
fi

xcodebuild -project "$repo_dir/NotchHarbor.xcodeproj" -scheme NotchHarbor \
  -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$build_dir/xcode" -clonedSourcePackagesDirPath "$package_dir" \
  -packageCachePath "$package_cache_dir" \
  -onlyUsePackageVersionsFromResolvedFile "${skip_updates_flag[@]}" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
  build

app="$build_dir/xcode/Build/Products/Release/Notch Harbor.app"
resources="$app/Contents/Resources"
helper="$app/Contents/XPCServices/BoringNotchXPCHelper.xpc"
plutil -replace CFBundleName -string 'Notch Harbor Helper' "$helper/Contents/Info.plist"

node "$repo_dir/scripts/build-folia-rail.mjs" "$folia_source" "$folia_deps" "$resources/FoliaRail.html"
cp "$repo_dir/LICENSE" "$repo_dir/THIRD_PARTY_LICENSES" "$resources/"
for component in AgentNotch Folia Lucide Maccy PowerFlow Shima SiriGlass apple-ble; do
  destination="$resources/ThirdParty/$component"
  mkdir -p "$destination"
  for file in LICENSE NOTICE.md UPSTREAM_NOTICE CONTRIBUTORS.md; do
    source="$repo_dir/THIRD_PARTY/$component/$file"
    if [[ -f "$source" ]]; then cp "$source" "$destination/"; fi
  done
done
for package in react react-dom scheduler framer-motion motion-dom motion-utils tslib @chenglou/pretext; do
  notice="$folia_deps/node_modules/$package/LICENSE"
  if [[ -f "$notice" ]]; then
    cp "$notice" "$resources/ThirdParty/Folia/${package//\//-}.LICENSE"
  fi
done

codesign --force --sign "$sign_identity" --timestamp=none "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign "$sign_identity" --timestamp=none --preserve-metadata=entitlements,flags "$helper"
codesign --force --sign "$sign_identity" --timestamp=none --preserve-metadata=entitlements,flags "$app"
codesign --verify --deep --strict "$app"
printf '\nBuild verified\n%s\n' "$app"

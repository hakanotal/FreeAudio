#!/bin/bash
# Build FreeAudio.app with the Command Line Tools only (no Xcode needed).
#
#   ./scripts/build-app-clt.sh            # arm64 release build (macOS 27 runs only on Apple silicon)
#   CODESIGN_IDENTITY=- ./scripts/build-app-clt.sh   # force ad-hoc signing
#
# Output: build/FreeAudio.app (signed with "FreeAudio Dev" if that certificate exists, else ad-hoc)
#
# Notes:
# - The CLT toolchain ships without the SwiftUIMacros plugin, so `@State` can't be expanded
#   as a macro. The build compiles a scratch copy of the sources that uses the
#   `SwiftUI.State` property wrapper through a typealias instead (same runtime behavior).
#   The repository sources are never modified.
# - Info.plist mirrors the INFOPLIST_KEY_* settings and `info:` properties in project.yml.
# - Ad-hoc signatures change on every build, so macOS forgets the System Audio Recording and
#   Accessibility grants each time. When a "FreeAudio Dev" code-signing certificate exists in the
#   keychain (self-signed, local only) it is used instead, so the grants survive rebuilds.
#   Release builds (build-dmg.sh) stay ad-hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
WORK="$BUILD/clt"
APP="$BUILD/FreeAudio.app"
SDK="$(xcrun --show-sdk-path)"
ARCHS="${ARCHS:-arm64}"
MIN_MACOS="27.0"
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  if security find-certificate -c "FreeAudio Dev" >/dev/null 2>&1; then
    CODESIGN_IDENTITY="FreeAudio Dev"
  else
    CODESIGN_IDENTITY="-"
  fi
fi

VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT/project.yml")"
BUILD_NUMBER="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT/project.yml")"
: "${VERSION:?MARKETING_VERSION not found in project.yml}"
: "${BUILD_NUMBER:=1}"

echo "==> FreeAudio $VERSION ($BUILD_NUMBER), archs: $ARCHS"
rm -rf "$WORK" "$APP"
mkdir -p "$WORK/src" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Preparing sources"
cp -R "$ROOT/FreeAudio" "$WORK/src/"
find "$WORK/src/FreeAudio" -name "*.swift" -exec sed -i '' 's/@State /@_CLTState /g' {} +
printf 'import SwiftUI\ntypealias _CLTState = SwiftUI.State\n' > "$WORK/src/FreeAudio/_CLTStateShim.swift"

SLICES=()
for ARCH in $ARCHS; do
  echo "==> Compiling $ARCH"
  (cd "$WORK/src" && swiftc -O -wmo -parse-as-library \
    -sdk "$SDK" -target "$ARCH-apple-macos$MIN_MACOS" \
    -swift-version 6 -strict-concurrency=minimal \
    -module-name FreeAudio \
    -module-cache-path "$WORK/module-cache" \
    $(find FreeAudio -name "*.swift") \
    -o "$WORK/FreeAudio-$ARCH")
  SLICES+=("$WORK/FreeAudio-$ARCH")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/FreeAudio"

echo "==> App icon"
ICONSET="$WORK/AppIcon.iconset"
IC="$ROOT/FreeAudio/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
cp "$IC/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$IC/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$IC/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$IC/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$IC/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$IC/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$IC/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$IC/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$IC/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$IC/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Info.plist"
COPYRIGHT="$(sed -n 's/^ *INFOPLIST_KEY_NSHumanReadableCopyright: *"\(.*\)"$/\1/p' "$ROOT/project.yml")"
AUDIO_CAPTURE="$(sed -n 's/^ *NSAudioCaptureUsageDescription: *"\(.*\)"$/\1/p' "$ROOT/project.yml")"
: "${AUDIO_CAPTURE:?NSAudioCaptureUsageDescription not found in project.yml}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>FreeAudio</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.freeaudio.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>FreeAudio</string>
    <key>CFBundleDisplayName</key><string>FreeAudio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
    <key>NSAudioCaptureUsageDescription</key><string>$AUDIO_CAPTURE</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (identity: $CODESIGN_IDENTITY)"
xattr -cr "$APP"
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements "$ROOT/FreeAudio/FreeAudio.entitlements" "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP"
lipo -info "$APP/Contents/MacOS/FreeAudio"

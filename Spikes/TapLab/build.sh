#!/bin/bash
# Build the TapLab spike app → build/TapLab.app (ad-hoc signed, arm64).
# Launch it with `open -n build/TapLab.app` so TapLab, not the terminal, owns the
# System Audio Recording permission.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="$ROOT/build/TapLab.app"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -sdk "$SDK" -target arm64-apple-macos27.0 \
  -swift-version 6 -strict-concurrency=minimal \
  -module-name TapLab \
  -module-cache-path "$ROOT/build/taplab-module-cache" \
  "$HERE/main.swift" "$HERE/Engine.swift" \
  -o "$APP/Contents/MacOS/TapLab"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
if [ -z "${CODESIGN_IDENTITY:-}" ] && security find-certificate -c "FreeAudio Dev" >/dev/null 2>&1; then
  CODESIGN_IDENTITY="FreeAudio Dev"
fi
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

# Tone players for spike S5: the same binary under two bundle IDs.
for NAME in ToneA ToneB; do
  TONE="$ROOT/build/$NAME.app"
  rm -rf "$TONE"
  mkdir -p "$TONE/Contents/MacOS"
  swiftc -O -sdk "$SDK" -target arm64-apple-macos27.0 -swift-version 6 -strict-concurrency=minimal \
    -module-name TonePlayer -module-cache-path "$ROOT/build/taplab-module-cache" \
    "$HERE/TonePlayer/main.swift" -o "$TONE/Contents/MacOS/$NAME"
  ID="com.freeaudio.taplab.$(echo "$NAME" | tr '[:upper:]' '[:lower:]')"
  cat > "$TONE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
  codesign --force --sign - "$TONE"
  echo "Built $TONE"
done

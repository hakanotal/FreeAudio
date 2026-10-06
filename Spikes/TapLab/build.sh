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
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

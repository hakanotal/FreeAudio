#!/bin/bash
# Build a release FreeAudio.app and package it as build/FreeAudio-<version>.dmg (manual
# installs) and build/FreeAudio-<version>.zip (in-app updates), each with a .sha256 file.
# Uses Xcode when available; otherwise falls back to the Command Line Tools build
# (scripts/build-app-clt.sh). Both produce an arm64 app (macOS 27 is Apple silicon only), signed
# with FreeAudio's certificate when this Mac has it (scripts/signing.sh), ad hoc otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="FreeAudio"
BUILD_DIR="$ROOT/build"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml)"
DMG_OUTPUT="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"

if xcodebuild -version >/dev/null 2>&1; then
  echo "=== Building ${APP_NAME} ${VERSION} with Xcode ==="
  # Skip Xcode's codesign; we sign manually after stripping xattrs
  xcodebuild -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    ARCHS="arm64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    clean build 2>&1 | tail -20
  APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/${APP_NAME}.app"
  [ -d "$APP_PATH" ] || { echo "ERROR: ${APP_NAME}.app not found in build output"; exit 1; }

  source "$ROOT/scripts/signing.sh"
  fa_sign_app "$APP_PATH" "$ROOT/$APP_NAME/$APP_NAME.entitlements"
else
  echo "=== Xcode not found; building ${APP_NAME} ${VERSION} with Command Line Tools ==="
  "$ROOT/scripts/build-app-clt.sh"
  APP_PATH="$BUILD_DIR/${APP_NAME}.app"
fi

# The zip the in-app updater installs (a mounted DMG is a removable volume, which the app may
# not read). ditto keeps the bundle's symlinks, permissions and signature.
ZIP_OUTPUT="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"
rm -f "$ZIP_OUTPUT"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_OUTPUT"

# Stage the app next to an /Applications shortcut for drag-to-install
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "=== Creating DMG ==="
# The mounted volume shows the app icon (the equalizer). hdiutil copies .VolumeIcon.icns but not
# the folder's custom-icon flag, so the flag is set on a read-write image, which is then compressed.
ICON="$APP_PATH/Contents/Resources/AppIcon.icns"
[ -f "$ICON" ] && cp "$ICON" "$STAGING_DIR/.VolumeIcon.icns"
RW_DMG="$BUILD_DIR/${APP_NAME}-rw.dmg"
rm -f "$DMG_OUTPUT" "$RW_DMG"
hdiutil create -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDRW \
  "$RW_DMG" >/dev/null
if [ -f "$ICON" ] && command -v SetFile >/dev/null; then
  MOUNT_DIR="$(mktemp -d)"
  hdiutil attach -nobrowse -mountpoint "$MOUNT_DIR" "$RW_DMG" >/dev/null
  SetFile -a C "$MOUNT_DIR" || true
  hdiutil detach "$MOUNT_DIR" >/dev/null
  rmdir "$MOUNT_DIR" 2>/dev/null || true
fi
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_OUTPUT" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGING_DIR"

for FILE in "$DMG_OUTPUT" "$ZIP_OUTPUT"; do
  (cd "$BUILD_DIR" && shasum -a 256 "$(basename "$FILE")" > "$(basename "$FILE").sha256")
done

echo "=== Done ==="
ls -lh "$DMG_OUTPUT" "$ZIP_OUTPUT"
cat "$DMG_OUTPUT.sha256" "$ZIP_OUTPUT.sha256"

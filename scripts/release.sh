#!/bin/bash
# Build the DMG and publish it as a GitHub Release.
#
#   ./scripts/release.sh            # version from project.yml (MARKETING_VERSION), tag v<version>
#   ./scripts/release.sh 2.1        # explicit version
#
# Requires the GitHub CLI (`gh auth login`) and the commit you want to release pushed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml)}"
VERSION="${VERSION#v}"
TAG="v${VERSION}"
DMG="build/FreeAudio-${VERSION}.dmg"
ZIP="build/FreeAudio-${VERSION}.zip"

# Installed copies only accept updates signed with FreeAudio's certificate.
source "$ROOT/scripts/signing.sh"
fa_has_signing_identity || { echo "ERROR: no \"$FA_SIGN_IDENTITY\" on this Mac. Run scripts/setup-signing.sh (--import the backup)."; exit 1; }
# The updater pins the certificate's SHA-1 (UpdateService.releaseCertificateSHA1).
PINNED="$(sed -n 's/.*releaseCertificateSHA1 = "\([0-9a-f]*\)".*/\1/p' FreeAudio/Services/UpdateService.swift)"
[ "$PINNED" = "$(fa_signing_identity_hash | tr 'A-F' 'a-f')" ] || { echo "ERROR: the updater pins certificate $PINNED, but this Mac signs with $(fa_signing_identity_hash)."; exit 1; }

echo "=== Building release ${TAG} ==="
./scripts/build-dmg.sh

# Check the app in the zip, the way the in-app updater sees it.
UNPACKED="$(mktemp -d)"
ditto -x -k "$ZIP" "$UNPACKED"
fa_require_release_signature "$UNPACKED/FreeAudio.app" || { rm -rf "$UNPACKED"; exit 1; }
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UNPACKED/FreeAudio.app/Contents/Info.plist")"
rm -rf "$UNPACKED"
# The updater only installs an app whose version equals the release tag.
[ "$BUNDLE_VERSION" = "$VERSION" ] || { echo "ERROR: the app is version $BUNDLE_VERSION, the tag is $TAG. Set MARKETING_VERSION in project.yml."; exit 1; }

# Release notes: the "## v<version>" section of CHANGELOG.md (up to the next "## " heading)
NOTES="$(mktemp)"
awk -v ver="## v${VERSION}" '
  index($0, ver) == 1 { found = 1; next }
  found && /^## / { exit }
  found { print }
' CHANGELOG.md > "$NOTES"
if [ ! -s "$NOTES" ]; then
  echo "No '## v${VERSION}' section in CHANGELOG.md; using generated notes"
  NOTES_ARGS=(--generate-notes)
else
  NOTES_ARGS=(--notes-file "$NOTES")
fi

echo "=== Creating GitHub Release ${TAG} ==="
gh release create "$TAG" \
  --title "FreeAudio ${TAG}" \
  "${NOTES_ARGS[@]}" \
  "$DMG" "$DMG.sha256" "$ZIP" "$ZIP.sha256"

rm -f "$NOTES"
echo "=== Release ${TAG} published ==="

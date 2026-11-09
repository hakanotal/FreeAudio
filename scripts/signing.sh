# Code-signing helpers shared by the build scripts. Source it: `source scripts/signing.sh`.
#
# Builds are signed with FreeAudio's self-signed certificate when this Mac has it (create it
# once with scripts/setup-signing.sh). The certificate keeps the app's designated requirement
# the same in every build, so:
# - macOS keeps the System Audio Recording and Accessibility permissions after an update (an
#   ad-hoc signature changes with every build, and macOS then asks for them again);
# - the in-app updater only installs an update signed with the same certificate.
# Without the certificate, builds are signed ad hoc (fine for local development, not for
# releases).

FA_SIGN_IDENTITY="FreeAudio Code Signing"
FA_SIGN_KEYCHAIN="$HOME/Library/Keychains/freeaudio-signing.keychain-db"
# The signing keychain's (generated) password is kept in the login keychain under this name.
FA_SIGN_PASSWORD_SERVICE="FreeAudio code signing keychain"

fa_has_signing_identity() {
  [ -f "$FA_SIGN_KEYCHAIN" ] && security find-generic-password -s "$FA_SIGN_PASSWORD_SERVICE" >/dev/null 2>&1
}

fa_unlock_signing_keychain() {
  local password
  password="$(security find-generic-password -s "$FA_SIGN_PASSWORD_SERVICE" -w 2>/dev/null)" || return 1
  security unlock-keychain -p "$password" "$FA_SIGN_KEYCHAIN"
}

# SHA-1 of the signing certificate (what a designated requirement's `certificate leaf` names).
fa_signing_identity_hash() {
  security find-identity -p codesigning "$FA_SIGN_KEYCHAIN" 2>/dev/null \
    | awk -v name="\"$FA_SIGN_IDENTITY\"" 'index($0, name) { print $2; exit }'
}

# fa_sign_app <app bundle> <entitlements file>
fa_sign_app() {
  local app="$1" entitlements="$2"
  xattr -cr "$app"
  if fa_has_signing_identity && fa_unlock_signing_keychain; then
    echo "==> Signing with \"$FA_SIGN_IDENTITY\""
    codesign --force --sign "$FA_SIGN_IDENTITY" --keychain "$FA_SIGN_KEYCHAIN" \
      --entitlements "$entitlements" "$app"
  else
    echo "==> Signing ad hoc (no \"$FA_SIGN_IDENTITY\" on this Mac; see scripts/setup-signing.sh)"
    codesign --force --sign - --entitlements "$entitlements" "$app"
  fi
  codesign --verify --strict "$app"
}

# Fails unless <app bundle> is signed with FreeAudio's certificate. Releases must be: the
# in-app updater of earlier versions rejects anything else.
fa_require_release_signature() {
  local app="$1" hash
  hash="$(fa_signing_identity_hash)"
  if [ -z "$hash" ] || ! codesign -d -r- "$app" 2>&1 | grep -qi "certificate leaf = H\"$hash\""; then
    echo "ERROR: $app is not signed with \"$FA_SIGN_IDENTITY\". Run scripts/setup-signing.sh (or restore the backup with --import) first."
    return 1
  fi
}

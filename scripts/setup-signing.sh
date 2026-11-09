#!/bin/bash
# Sets up FreeAudio's code-signing certificate on this Mac (see scripts/signing.sh for why).
#
#   ./scripts/setup-signing.sh [backup.p12]   # create it once and write an encrypted backup
#                                            # (default ~/Documents/FreeAudio-signing-backup.p12)
#   ./scripts/setup-signing.sh --import backup.p12   # restore it from a backup (another Mac)
#
# The backup password is read from the file named by FA_BACKUP_PASSWORD_FILE, or asked for.
#
# KEEP THE BACKUP AND ITS PASSWORD. Installed copies only accept updates signed with this
# certificate. A new certificate means every user has to update by hand once and grant the
# System Audio Recording and Accessibility permissions again.
#
# The certificate lives in its own keychain (~/Library/Keychains/freeaudio-signing.keychain-db)
# with a generated password stored in the login keychain, so builds sign without prompts.
set -euo pipefail

source "$(dirname "$0")/signing.sh"

# Always the system LibreSSL: Homebrew's OpenSSL 3 writes PKCS#12 files the keychain can't read.
OPENSSL=/usr/bin/openssl
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

read_password() {  # read_password <prompt> → stdout
  if [ -n "${FA_BACKUP_PASSWORD_FILE:-}" ]; then
    cat "$FA_BACKUP_PASSWORD_FILE"
  elif [ -t 0 ]; then
    local password
    read -r -s -p "$1: " password; echo >&2
    printf '%s' "$password"
  else
    echo "ERROR: set FA_BACKUP_PASSWORD_FILE or run in a terminal" >&2
    return 1
  fi
}

# install_identity <p12> <p12 password>: a fresh signing keychain holding the identity.
install_identity() {
  local p12="$1" p12_password="$2" keychain_password
  keychain_password="$("$OPENSSL" rand -hex 24)"
  security create-keychain -p "$keychain_password" "$FA_SIGN_KEYCHAIN"
  security set-keychain-settings "$FA_SIGN_KEYCHAIN"   # no auto-lock
  security unlock-keychain -p "$keychain_password" "$FA_SIGN_KEYCHAIN"
  security import "$p12" -k "$FA_SIGN_KEYCHAIN" -P "$p12_password" -T /usr/bin/codesign >/dev/null
  # Let codesign use the key without a keychain prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" \
    "$FA_SIGN_KEYCHAIN" >/dev/null
  security add-generic-password -U -a "$USER" -s "$FA_SIGN_PASSWORD_SERVICE" \
    -l "$FA_SIGN_PASSWORD_SERVICE" -w "$keychain_password" -T /usr/bin/security
}

# A signing keychain without its password item: never overwrite it (it may hold the only key).
if ! fa_has_signing_identity && [ -e "$FA_SIGN_KEYCHAIN" ]; then
  echo "ERROR: $FA_SIGN_KEYCHAIN exists but its password is missing from the login keychain."
  echo "Restore from the backup with --import after moving that file away."
  exit 1
fi

if [ "${1:-}" = "--import" ]; then
  BACKUP="${2:?usage: $0 --import backup.p12}"
  if fa_has_signing_identity; then
    echo "\"$FA_SIGN_IDENTITY\" already exists on this Mac; nothing imported."
    exit 0
  fi
  PASSWORD="$(read_password "Backup password")"
  install_identity "$BACKUP" "$PASSWORD"
  echo "Imported \"$FA_SIGN_IDENTITY\" (SHA-1 $(fa_signing_identity_hash))."
  exit 0
fi

if fa_has_signing_identity; then
  echo "\"$FA_SIGN_IDENTITY\" already exists (SHA-1 $(fa_signing_identity_hash)); nothing to do."
  exit 0
fi

BACKUP="${1:-$HOME/Documents/FreeAudio-signing-backup.p12}"
[ -e "$BACKUP" ] && { echo "ERROR: $BACKUP already exists; restore it with --import or pick another path."; exit 1; }
PASSWORD="$(read_password "Password for the backup")"
[ "${#PASSWORD}" -ge 8 ] || { echo "ERROR: use a backup password of at least 8 characters."; exit 1; }

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $FA_SIGN_IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
"$OPENSSL" req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The backup, encrypted with the chosen password; it is also what gets imported below.
FA_P12_PASSWORD="$PASSWORD" "$OPENSSL" pkcs12 -export -name "$FA_SIGN_IDENTITY" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout env:FA_P12_PASSWORD -out "$WORK/identity.p12"
install_identity "$WORK/identity.p12" "$PASSWORD"
mkdir -p "$(dirname "$BACKUP")"
cp "$WORK/identity.p12" "$BACKUP"
chmod 600 "$BACKUP"

echo "Created \"$FA_SIGN_IDENTITY\" (SHA-1 $(fa_signing_identity_hash))."
echo "Backup: $BACKUP. Keep it and its password somewhere safe (a password manager)."

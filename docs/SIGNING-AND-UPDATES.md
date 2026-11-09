# Signing and in-app updates

How FreeAudio signs its builds without an Apple Developer account and updates itself with one click (since v2.2). Ported from FreeDisplay v2.4, which has the same setup.

## Why

Up to v2.1, every update cost users four steps: download the DMG, drag it to Applications, click **Open Anyway** for Gatekeeper, and grant System Audio Recording (and Accessibility, for the volume keys) again. The last two come from how the app was signed:

- **Ad-hoc signatures change every build.** An ad-hoc signature's designated requirement (what macOS uses to recognise "the same app") is its code hash, so each build counts as a new app and macOS forgets its privacy grants.
- **Downloaded files are quarantined.** A browser marks the DMG, and Gatekeeper blocks the unnotarized app once on first launch.

The fix has two parts:

1. **Sign every build with one self-signed certificate.** The designated requirement becomes `identifier "com.freeaudio.app" and certificate leaf = H"<certificate hash>"`, the same in every build. macOS keeps the grants, and the updater can insist that an update satisfies it.
2. **Install updates from inside the app.** A file the app downloads itself with URLSession isn't quarantined, so the new version opens without the Gatekeeper prompt.

The very first download from the website still shows **Open Anyway** once. Only notarization ($99/year) removes that.

## The certificate

**"FreeAudio Code Signing"**, SHA-1 `8F91F55BA1B09414250A4EBA77C5370BE81AE910`, created 2026-11-08, valid 20 years.

- It lives in its own keychain, `~/Library/Keychains/freeaudio-signing.keychain-db`, whose generated password is stored in the login keychain as "FreeAudio code signing keychain". Builds unlock it without prompts.
- The encrypted backup is `~/Documents/FreeAudio-signing-backup.p12`. **Keep it and its password in a password manager.** Installed copies only accept updates signed with this certificate. With a new one, every user would have to update by hand once and grant the permissions again. Never commit the key or the backup (`*.p12` is git-ignored).
- To restore it on another Mac: `./scripts/setup-signing.sh --import backup.p12` (asks for the backup password, or reads it from the file named by `FA_BACKUP_PASSWORD_FILE`).

`scripts/setup-signing.sh` (run once, already done) creates an RSA 3072 key and a self-signed code-signing certificate with `/usr/bin/openssl` (LibreSSL: Homebrew's OpenSSL 3 writes PKCS#12 files the keychain refuses), writes the encrypted backup at creation time (exporting a private key later always shows a GUI confirmation), imports it into the dedicated keychain with `-T /usr/bin/codesign`, and runs `set-key-partition-list` so codesign can use the key without a prompt.

The certificate isn't trusted, and doesn't need to be: `codesign` signs with it, `codesign --verify` passes, and TCC only compares the certificate hash. `security find-identity` lists it as `CSSMERR_TP_NOT_TRUSTED`, and `codesign -dv` shows no `Authority=` line. To check a signature, read `codesign -d -r-`.

## Builds and releases

`scripts/signing.sh` is sourced by the build scripts:

- **`fa_sign_app <app> <entitlements>`** strips extended attributes and signs with the certificate when this Mac has it, ad hoc otherwise (fine for contributors).
- **`fa_require_release_signature <app>`** fails unless `codesign -d -r-` names the certificate's SHA-1.

`scripts/build-dmg.sh` produces two artifacts, each with a `.sha256` file:

- **`FreeAudio-x.y.dmg`** for manual installs (drag to Applications).
- **`FreeAudio-x.y.zip`** for the updater, made with `ditto -c -k --keepParent`. Not the DMG: a mounted disk image is a removable volume, which the app may not read (EPERM). `ditto` keeps the bundle's symlinks, permissions and signature.

`scripts/release.sh` refuses to run without the certificate, unpacks the zip and checks its signature and that its version matches the tag (the updater requires both), then uploads all four files with the `## vX.Y` section of `CHANGELOG.md` as notes.

## The updater (`UpdateService`)

1. **Check** at launch, every 6 hours, and when the panel opens (at most hourly), unless Settings → "Check for updates automatically" is off. It reads `api.github.com/repos/hakanotal/FreeAudio/releases/latest` with an ephemeral, cache-free URLSession (a revalidated cached request can come back as 304) and takes the tag, the release page and the `.zip` and `.zip.sha256` assets.
2. **Can it update itself?** Only with both assets and write access to the app bundle and its folder (not translocated, not read-only). Otherwise the banner only shows **View** (the release page).
3. **Download** the checksum and the zip into `itemReplacementDirectory` for the app's volume, so the final swap is a rename, and compare the SHA-256 (CryptoKit).
4. **Unpack** with `ditto -x -k`.
5. **Verify:** the app must have the running app's bundle ID and the tag's version, and `SecStaticCodeCheckValidity` (strict, all architectures, nested code) must pass with the running app's own designated requirement, which names the certificate. An ad-hoc dev build has no certificate to pin and only checks that the signature is valid.
6. **Flush** debounced settings (`SettingsService.flushPendingSaves`), then **swap** with `FileManager.replaceItemAt(…, options: .usingNewMetadataOnly)`. The running process keeps its old files until it exits.
7. **Relaunch** with `NSWorkspace.openApplication` (`createsNewApplicationInstance`, argument `--after-update`). The new copy terminates the old one, which tears down its taps as on any quit, and starts audio as soon as the old process is gone. It skips the hand-over to the launch agent: launchd's first start of a newly written executable is refused ("Launch Constraint Violation"), so the agent starts the new version from the next login. If LaunchServices fails, a launchd-started copy falls back to `launchctl kickstart -k`; otherwise the banner asks the user to reopen FreeAudio.
8. **Logging:** `log show --predicate 'subsystem == "com.freeaudio.app" AND category == "update"'` (use `/usr/bin/log` in zsh, whose `log` builtin shadows it).

The banner reads "New version vX available" with **View** and **Update**; while working it shows a spinner with "Downloading…" or "Installing…", and on failure the reason in red.

## Permissions after the switch

- **System Audio Recording:** a record made under another signature (every ad-hoc build, or the old "FreeAudio Dev" certificate) reads as not determined (`TCCAccessPreflight` returns 2), so `PermissionService` shows the system prompt again by itself the first time a tap is needed. No reset is needed.
- **Accessibility (volume keys):** records from another signature deny the event tap silently, and turning FreeAudio on in the list doesn't repair them. The first time a build can't start the tap (once per build, so a user who declined isn't asked at every launch), and when the user clicks **Open** next to Settings → Volume keys, `VolumeKeyService` runs `tccutil reset Accessibility|PostEvent|ListenEvent com.freeaudio.app` (only FreeAudio's own records) and `AXIsProcessTrustedWithOptions` with the prompt option. It retries on the `com.apple.accessibility.api` notification and every 10 s, so the keys start without a restart.

Users upgrading from v2.1 or earlier go through both prompts once. From v2.2 on, updates keep the grants.

## How it was tested (2026-11-08)

From a scratch copy of the repo with a test bundle ID (`com.freeaudio.updatetest`), the feed pointed at a local `python3 -m http.server`, and audio startup replaced by "check, then install"; nothing test-only is in the sources:

- **Forged update:** 9.9.1 re-signed ad hoc, with a correct checksum, was refused (`Update to 9.9.1 failed: signature`), and the app stayed on 9.9.
- **Signed update:** 9.9 downloaded, verified, swapped and relaunched into 9.9.1 with `--after-update`; the new copy found no newer release, and no crash report was written.
- The first run showed the new copy waiting the full 5 s for the old one although it had quit in 0.3 s (`NSRunningApplication.isTerminated` lagged). With `kill(pid, 0)` the new copy took over 0.45 s after the swap.
- Release check: `fa_require_release_signature` passed on the app unpacked from the v2.2 zip.

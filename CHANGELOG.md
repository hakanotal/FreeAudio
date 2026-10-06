# Changelog

All notable changes to FreeAudio are documented here.

---

## Unreleased

- Project created from FreeDisplay v2.2 (commit `ae8f045`): same app shell, build and release scripts, Turkish/English UI and visual style, with its own identity (`com.freeaudio.app`, version 0.1)
- Removed all display features inherited from FreeDisplay; the panel now shows Settings and the footer, with a speaker menu bar icon
- Requires macOS 27 on Apple silicon; builds are arm64 only
- Output device row: shows the current output, expands to the device list to switch output (alert sounds follow), marks devices without hardware volume
- Output volume slider and mute for devices with hardware volume, kept in sync with the keyboard and System Settings
- App list: the apps playing audio, with icons, helper processes grouped under their app (read-only for now)
- `FreeAudio --dump-audio` prints a diagnostics snapshot of devices and app grouping
- Per-app volume: a slider, mute button and boost (Off / 150% / 200%) for every app playing audio, remembered per app. Apps at default settings are left untouched; controlled apps are muted at the source and replayed at the chosen level
- Apps with saved settings are controlled from their first sound, also after a relaunch
- Asks for System Audio Recording permission the first time it is needed; a notice links to System Settings when it is denied
- Settings: permission status, list of saved app settings with reset, and "Restart audio engine"

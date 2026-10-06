# Changelog

All notable changes to FreeAudio are documented here.

---

## v1.0 (2026-10-06)

First release. FreeAudio is a free, open-source menu bar app for per-app audio on macOS 27 (Apple silicon).

- **Per-app volume:** a slider, mute button and boost (150% or 200%) for every app playing audio. Helper processes of browsers and Electron apps are grouped under their app. Settings are remembered per app and apply from the app's first sound, also after a relaunch. Apps left at default are never touched.
- **Output device:** the current output with its volume and mute, and a device list to switch outputs (alert sounds follow). Stays in sync with the keyboard and System Settings.
- **Software volume for HDMI/DisplayPort monitors:** outputs without a hardware volume control get a working slider and mute, system sounds included, and per-app levels combine with it. "Use Software Volume" in a device's context menu forces it for devices whose hardware control doesn't work.
- **Volume keys on those outputs,** with a volume HUD at the top right (16 steps, Option+Shift for finer steps). On other outputs the keys behave as usual.
- **Robust:** follows output changes (headphones, AirPods, monitors), sample-rate changes, sleep and audio-service restarts. Idle audio engines stop so the Mac can still sleep. Quitting FreeAudio, or a crash, returns every app to its normal volume.
- **Permissions:** asks for System Audio Recording the first time it is needed, with a notice and a link to System Settings if it is denied. Accessibility is only needed for the volume keys.
- **App:** Turkish and English UI, launch at login with crash restart, update check, a list of saved app settings and "Restart audio engine" in Settings, and a notice when another audio app that taps apps (SoundSource, FineTune, eqMac and others) is running.
- Requires macOS 27 on Apple silicon.

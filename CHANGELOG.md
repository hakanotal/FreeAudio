# Changelog

All notable changes to FreeAudio are documented here.

---

## Unreleased

- **Per-app output routing:** choose an output for any app in its detail view (click the app's name). The choice is remembered per app; while that device isn't connected the app plays on the system default and moves back when it returns. Routed apps show a small device icon next to their name, and apps routed to a monitor with software volume get that monitor's level
- **Easier sliders:** every volume slider snaps to 0, 25, 50, 75 and 100% (with a light haptic click on Force Touch trackpads) and shows tick marks there
- **App sliders run from 0 to 200%** with 100% (unchanged) in the middle, so boosting is just dragging past the middle; the separate boost picker is gone. Saved v1.0 settings convert to the same loudness. The output and input sliders stay 0–100%
- **Input device and level:** Tools → Input shows the current microphone; expand it to switch microphones and set the input level and mute (the slider is disabled for microphones whose level can't be changed). No extra permission needed

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

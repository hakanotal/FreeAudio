# Changelog

All notable changes to FreeAudio are documented here.

---

## v2.0 (2026-10-07)

- **New icon:** an equalizer in the menu bar, for the app and on the installer disk image (volume sliders keep their speaker symbols)
- **Snappier panel:** sections and dropdowns open at once with a quick fade and close instantly, instead of a slow spring that lagged behind the window
- **Per-app output routing:** choose an output for any app in its detail view (click the app's name). The choice is remembered per app; while that device isn't connected the app plays on the system default and moves back when it returns. Routed apps show a small device icon next to their name, and apps routed to a monitor with software volume get that monitor's level
- **All open apps that play sound are listed,** not only the ones playing right now, so you can set an app's level before it makes a sound. Idle apps have a dimmed icon; playing apps show a small waveform. Background processes (system services, menu bar helpers, command-line tools) still only appear while they play
- **Hide apps:** point at an app and click the crossed-out eye that appears next to its name (or right-click → Hide). Hovering also shows a reset button for apps with changed settings. Hidden apps that are open collect under "Hidden apps" at the bottom; expand it to adjust them or choose Show to bring one back. Hiding is only visual: a hidden app's saved level, mute and output still apply
- **Easier sliders:** every volume slider snaps to 0, 25, 50, 75 and 100% (with a light haptic click on Force Touch trackpads) and shows tick marks there
- **App sliders run from 0 to 200%** with 100% (unchanged) in the middle, so boosting is just dragging past the middle; the separate boost picker is gone. Saved v1.0 settings convert to the same loudness. The output and input sliders stay 0–100%
- **Input device and level:** Tools → Input shows the current microphone; expand it to switch microphones and set the input level and mute (the slider is disabled for microphones whose level can't be changed). No extra permission needed

Fixes:

- Apps on a mono output (AirPods during a call, mono USB speakerphones) now play both channels instead of only the right one
- On audio interfaces with several output streams, controlled apps play to the main outputs (the preferred stereo pair) instead of the second stream
- Audio at 100% or below is passed through untouched; the limiter only works while boosting, and blends in smoothly past 100%
- Setting an app back to "System default" at 100% moves its audio back at once, also when its device was disconnected
- No level bump on the first drag of an app's slider on a monitor with software volume, and no click on the old output when an app moves to another one
- An engine that failed to start is retried after a short pause instead of waiting for some other change; a muted app no longer plays at full volume meanwhile
- The "audio engine isn't responding" notice clears by itself once the system responds again, and a slow start no longer leaves an app silent
- Monitors with software volume never jump to full level when the volume engine can't be rebuilt; the running one stays until its replacement works
- Granting or revoking System Audio Recording in System Settings takes effect within seconds, without opening the panel
- Sliders can be moved with the arrow keys and VoiceOver (snap points apply only while dragging)
- After the audio service restarts, the output and input sliders keep following the keyboard and System Settings

Performance:

- Much less work per app-list refresh: process details are read once per process instead of every second or five, and AppKit lookups are cached
- The audio callback takes a lighter path whenever the level isn't changing
- No timers run while nothing is controlled, and dragging a slider redraws only its own row

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

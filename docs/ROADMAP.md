# FreeAudio roadmap

Approved 2026-10-06. This is the working plan; `docs/FREEAUDIO_BRIEF.md` keeps the background (Core Audio approach, style guide). Where they differ, this file wins.

## Context

FreeAudio was created as a copy of FreeDisplay v2.2 with a new identity and still contains all of FreeDisplay's display code. `docs/FREEAUDIO_BRIEF.md` defines the product (a free SoundSource alternative: per-app volume and mute, output device control, software volume for HDMI/DisplayPort outputs, volume keys) and a phased plan. [FineTune](https://github.com/ronitsingh10/FineTune) is a mature open-source app (GPLv3, about 28k lines of Swift, macOS 15.4+) that does the same job with Core Audio process taps. All of it was studied at commit `2285279` (v1.9.0), plus a research document that only exists in its git history (`docs/research/harness-coreaudio-mechanics.md` at commit `df7b472`), and the engine design below was reviewed separately. The local clone was removed afterwards; everything worth keeping is in this file.

This roadmap merges the brief, what FineTune teaches (and gets wrong), and the decisions taken with the user.

## Decisions (taken with the user, 2026-10-06)

| Topic | Decision | Consequence |
|---|---|---|
| License | FreeAudio stays **MIT**. FineTune is a design reference only. | Behaviours, API sequences, constants and pitfalls are reused as facts. No copied code, no line-by-line ports, no copied test fixtures. Add this rule to `CLAUDE.md`. |
| Minimum macOS | **27.0** (overrides the brief's 14.2) | `CATapDescription.bundleIDs` / `processRestoreEnabled`, `Synchronization.Atomic`, `windowResizeAnchor` are available with no fallbacks. macOS 27 runs only on Apple silicon, so builds become **arm64 only**. |
| Private APIs | **Approved:** `responsibility_get_pid_responsible_for_pid` and `TCCAccessPreflight`/`TCCAccessRequest` | Both loaded with `dlopen`/`dlsym`, with a public fallback when missing. The OSDUIHelper XPC inherited from FreeDisplay is dropped: spike S9 showed it draws the old centered OSD. Record the approvals in `CLAUDE.md`. |
| Xcode project | **Install XcodeGen** (`brew install xcodegen`, dev tool only) | Regenerate `FreeAudio.xcodeproj` from `project.yml` whenever files change. |
| Boost | **Up to 200%**: Off / 150% / 200% | Soft limiter at the end of the chain. |
| Tests | **Swift Testing package for pure logic** | `swift test` with the Command Line Tools (Testing.framework ships with CLT; XCTest does not). |
| First post-MVP feature | **Per-app output routing** | The engine takes a target device per app from day one. |

Build machine: macOS 27.0.1, Swift 6.4, Command Line Tools only, Homebrew present. The Observation macro plugin is available; the SwiftUI macro plugin is not (hence the `@State` shim in `scripts/build-app-clt.sh`).

## What FineTune teaches

**Adopt (as facts, re-implemented):**
- Tap configuration: `mutedWhenTapped` + private tap + private, *stacked* aggregate, `TapAutoStart` on, main and clock sub-device = the output UID. Their test harness showed this avoids recording doubling.
- Sub-tap drift compensation **off** when the output is Bluetooth or virtual (otherwise a rhythmic crackle every ~0.7 s on calls).
- Read the tap's real UID back with `kAudioTapPropertyUID` instead of trusting the description's UUID.
- Teardown order: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` (blocks until the cycle ends) → destroy aggregate → destroy tap. A new tap for the same app must wait for the previous teardown.
- Gain ramp: one-pole per sample, `coef = 1 - exp(-1/(sr*0.030))`, **seeded to the target before `AudioDeviceStart`** (otherwise the first buffer blasts at 100%).
- Output gate: after idle the HAL can deliver a stale buffer. Hold output at 0 until peak > 1e-4, fade in over 40 ms, re-arm after 200 ms of silence.
- Buffer mapping: with more input than output buffers, the tap is the trailing input buffers (USB duplex silence bug). Stereo goes to `kAudioDevicePropertyPreferredChannelsForStereo` (1-based); mono is duplicated.
- Write `kAudioDevicePropertyIOProcStreamUsage` to disable a duplex device's hardware inputs, or macOS shows the microphone indicator. Never write an all-unused map.
- Rebuild the aggregate on a sample-rate change; changing the rate in place silences the IOProc. Bluetooth A2DP↔HFP keeps the same `AudioObjectID` and only changes the nominal rate (below 44.1 kHz = call mode). Ignore rate reads of 0.
- Device list notifications arrive in bursts: debounce 50 ms. Bluetooth volume reads 1.0 for ~300 ms after connect: re-read. Left/right volume notifications are duplicates: drop equal values.
- Volume curves: app and software-device sliders use gain = slider²; hardware sliders map 1:1 to `VirtualMainVolume` (the driver already tapers; squaring kills the bottom of the slider). Don't floor software volumes to 0.
- CFString properties are +1 retained (`takeRetainedValue`). Some HAL plug-ins write past the expected size on string reads: use heap buffers. Tolerate `kAudioHardwareBadObjectError` when removing listeners.
- Keep a tap ~30 s after its process disappears: `IsRunning` flickers during device changes.
- Persistence: one JSON file, tolerant per-key decoding, a backup copy of a corrupt file, debounced (500 ms) atomic save, synchronous flush on quit.
- Volume keys: `NX_SYSDEFINED` (14), subtype 8, key types 0/1/7. Consume only what you handle; key-ups and mute repeats pass through. Event taps go inert after wake: re-check `CGEvent.tapIsEnabled`. A "retry" must tear the tap down before creating it again.
- Pure-logic seams (render kernel as a static function, protocols for device and process providers) make the hard parts unit-testable.

**Do differently (FineTune gaps):**
- FineTune taps **every** audio app. FreeAudio taps only apps with non-default settings (brief), which means less CPU and fewer failure modes.
- FineTune freezes the process list at tap creation, so helpers that start later play untapped. FreeAudio updates the tap (in-place `kAudioTapPropertyDescription` if spike S4 passes, otherwise a crossfaded rebuild).
- FineTune's software volume only scales tapped apps, so system sounds and new apps play at full level on HDMI. FreeAudio adds a device-scoped "rest" tap (see engine design).
- Use `kAudioProcessPropertyIsRunningOutput`, not `IsRunning` (which lists microphone-only apps).
- Helper grouping order: responsibility API (covers WebKit XPC) → outermost `.app` in `proc_pidpath` (Chrome/Electron helpers) → the process's own bundle → parent-PID walk. FineTune checks the own bundle first, which breaks for Electron helpers that are `.app` bundles themselves (confirmed with TapLab, see LESSONS).
- Use the macOS 15+ Swift Core Audio object API (`AudioHardwareSystem`, `AudioHardwareDevice`, `AudioHardwareProcess`, `AudioHardwareTap`, `AudioHardwareAggregateDevice`, `PropertyListenerDelegate`) for discovery and setup. FineTune hand-rolls property access. Only the IOProc and a few properties (`VirtualMainVolume`, mute, `IOProcStreamUsage`) need the C API.
- Run the IOProc as a C function (`AudioDeviceCreateIOProcID` + client-data pointer), not a block. That avoids ARC on the HAL thread and the Swift 6 isolation trap FineTune crashed on.
- Use `Atomic` from `Synchronization` instead of plain `nonisolated(unsafe)` vars and `OSMemoryBarrier`.
- Ramp mute out over ~20 ms instead of an instant memset. Interpolate gate and crossfade gains per sample.
- Handle `kAudioHardwarePropertyServiceRestarted` (coreaudiod restart) and wake, which FineTune ignores.
- No 2,000-line engine class: split discovery, device volume and tap reconciliation into separate services.

**Skip:** FluidMenuBarExtra and its status-item hacks, Sparkle (keep FreeDisplay's GitHub check), KeyboardShortcuts, custom HUD windows (use the native OSD), multi-device output, AutoEQ, loudness processors, device priority auto-switching, Bluetooth connect, device icon picker, URL schemes, popup keyboard navigation (later at most).

## Target architecture

Views → Services → system frameworks, as in FreeDisplay. Services are `@MainActor final class … : ObservableObject, @unchecked Sendable` singletons. `AudioManager` is owned by `AppDelegate`.

```
FreeAudio/
  App/        FreeAudioApp (MenuBarExtra, speaker.wave.2.fill), AppDelegate (owns AudioManager; single instance, launchd hand-off, sleep/wake)
  Core/       Pure logic, compiled into the app AND the test package: VolumeCurve, RenderKernel,
              SoftLimiter, OutputGate, AppGrouping, EngineDiff, AppSetting/DeviceSetting (Codable),
              MediaKeyDecoder, DeviceTier
  Audio/      Core Audio wrappers, not @MainActor: CoreAudio+Extensions (what the Swift API lacks), HALQueue,
              RealtimeState, TapEngine, PrivateAPI (dlsym: responsibility, TCC)
  Services/   AudioManager, DeviceService, AppAudioService, DeviceVolumeService, TapService,
              PermissionService, VolumeKeyService, VolumeHUDService, SettingsService, LaunchService, UpdateService
  Models/     AudioApp, AudioDevice
  Views/      MenuBarView, OutputDeviceRow, DeviceListView, VolumeSliderRow, AppVolumeRow,
              AppDetailView, PermissionRow, SettingsView
Spikes/TapLab/   Throwaway probe app for the spikes (own bundle ID, own build script, outside the app build)
Tests/FreeAudioCoreTests/   Swift Testing
Package.swift    target FreeAudioCore (path: FreeAudio/Core) + test target
```

| Type | Responsibility |
|---|---|
| `AudioManager` | Glue: wires discovery, device and settings events into `TapService.reconcile()`; tracks panel visibility for poll rates. |
| `DeviceService` | Output device list (hidden and own aggregates filtered), default and system-default output, switching, sample-rate and alive listeners. Keyed by UID. |
| `AppAudioService` | Process objects → `AudioApp` groups by bundle ID, `IsRunningOutput`, the devices each app plays to, listeners plus poll (1 s with panel open, 5 s closed), 3 s row grace. |
| `DeviceVolumeService` | Tier per device (hardware if `VirtualMainVolume` is settable, else software; per-UID "force software" override), hardware volume/mute, software volume/mute persisted per UID. |
| `TapService` | Desired-state reconciler: computes the engine set from apps, settings, tiers and permission; applies the difference on `HALQueue`; health watchdog; quit teardown. |
| `TapEngine` | One tap + private aggregate + C IOProc + `RealtimeState`. Kinds: `app` (one controlled app), `rest` (software volume), possibly `muteOnly` (spike S6). |
| `PermissionService` | `TCCAccessPreflight` status (authorized / denied / unknown), request, re-check on panel open and app activation, zero-buffer safety net. |
| `VolumeKeyService`, `VolumeHUDService` | Adapted from `BrightnessKeyService` / `BrightnessHUDService`. |

### Engine design

- **Selective tapping.** An app is "controlled" when its setting is not default (volume ≠ 100%, muted, boosted, or later routed). A controlled app gets an `app` engine as soon as its process objects exist, not only while it plays. The engine stays alive at 100% while the app runs, so dragging through 100% doesn't create and destroy taps; it goes away 30 s after the app quits or after the app sits at defaults and idle.
- **App tap.** `CATapDescription(stereoMixdownOfProcesses:)` with the process objects of the app and its helpers, private, `mutedWhenTapped`. Use only the app's own bundle ID in `bundleIDs` (never shared helper IDs such as `com.apple.WebKit.GPU` or `com.github.Electron.helper`, which belong to many apps), and only if spike S5 passes. The engine plays to the device the app actually uses (`kAudioProcessPropertyDevices`, output scope), falling back to the default output.
- **Rest tap (software volume, Phase 4).** When an output has no hardware volume and its software volume is below 100% or muted, run one `rest` engine built with `initExcludingProcesses:andDeviceUID:withStream:` scoped to that device. It only catches audio bound for that device (system sounds included) and goes quiet on its own when the default changes. App engines on that device multiply in the device gain.
- **Ownership invariant.** Every process the rest tap excludes must be inside a running app engine; otherwise it plays at raw HDMI level. Both sides use process objects in v1. When an app becomes controlled: start its app engine at gain 0, start the replacement rest tap R′ at gain 0, wait for first callbacks, then do a linear crossfade scheduled in host time (R 1→0, R′ 0→1, app engine 0→target). Never destroy R before R′ runs. `EngineDiff` asserts the invariant and is unit-tested.
- **Real-time state.** `RealtimeState` lives in manually allocated memory: `Atomic<UInt32>` Float bit patterns for target gain, mute and crossfade schedule, plus peak, callback count, last host time and a one-shot buffer-layout snapshot. The C IOProc gets the pointer as client data. No allocation, locks, logging, ARC or actor hops in the callback.
- **Render kernel** (`Core/RenderKernel.swift`, pure static function): map input to output buffers, per-sample ramp, mute ramp, output gate, crossfade multiplier, gain, soft limiter (only matters above unity gain), post-gain peak. Unit-tested on synthetic buffer lists.
- **HAL queue.** All create → alive → IOProc → start → stop → destroy work runs on one serial queue, so teardown is ordered before re-creation. Poll `kAudioDevicePropertyDeviceIsAlive` with a 5 ms sleep, up to 2 s, on that queue (spike S1 confirms this works while main is free; if it doesn't, set `kAudioHardwarePropertyRunLoop` to NULL at launch). Each operation has a timeout. `CGHelpers.runWithTimeout` returns on timeout but the stuck call keeps occupying the serial queue, so a timeout puts `TapService` into a visible "engine stuck" state instead of an automatic retry loop.
- **Reconciler.** The main actor computes the desired engine set (key → kind, process objects, device, gain). Changes are debounced ~200 ms and tagged with a generation number, so a burst of wake, device and rate events becomes one pass. Gain-only changes write the atomics directly with no rebuild. Replacing an engine on a live device uses the crossfade; on a dead device it tears down first and fades in.
- **Naming.** Aggregate UID prefix `com.freeaudio.agg.`, name `FreeAudio <app>`. Filter them out of the device list; sweep any visible leftovers at launch.

### Persistence

- `~/Library/Application Support/FreeAudio/apps.json`: `[bundleID: AppSetting]`, with `volume` (slider 0–1, default 1), `muted`, `boost` (1 / 1.5 / 2) and later `outputDeviceUID`.
- `devices.json`: `[deviceUID: DeviceSetting]`, with `softwareVolume`, `softwareMuted`, `forceSoftware`.
- Codable with `decodeIfPresent` defaults; back up a corrupt file and start fresh. 500 ms debounced atomic write via `SettingsService.save`; flush in `applicationWillTerminate`.
- Simple flags stay in UserDefaults with the `fa.` prefix. `migrateLegacyDefaults` becomes an empty versioned stub.

### Panel

This follows the brief's mockup and FreeDisplay's style:
1. Output device row (`ExpandableRow` pattern, expands to the device list, tap to set default) with a volume row below it (Hardware/Software status dot, mute button).
2. "Apps" header, then one `AppVolumeRow` per playing app: 20×20 app icon, name, slider, % label with accent flash, mute button. It expands to `AppDetailView` with boost, reset, and later the output picker. "Muted" and "Boost" badges.
3. Permission row when needed, and an empty state ("Şu anda ses çalan uygulama yok" / "No apps are playing audio").
4. Settings: language, launch at login, update check, permission and Accessibility status, saved app settings (reset or forget), "restart audio engine".
5. Footer.

## Spikes (run in `Spikes/TapLab`, results go into `docs/LESSONS.md` → new "Audio" section)

| ID | Question | Pass criterion | When |
|---|---|---|---|
| S1 | Basic engine: Music tap, aggregate, C IOProc, readiness polled on a background queue; behaviour with permission denied; TCC preflight return values | Alive < 500 ms with main idle; `AudioDeviceStart` with the app paused returns < 100 ms; denial behaviour recorded | Phase 0 |
| S2 | Device-scoped rest tap on the Dell (HDMI via USB-C), excluding the probe itself; `afplay` to the speakers at the same time | Only HDMI-bound audio scaled; no feedback; switching the default away leaves R silent without errors | Phase 0 |
| S6 | Bare `CATapMuted` tap with no aggregate as a mute mechanism | App stays silent across default switches; audible again when the tap is destroyed and when the probe is killed | Phase 0 |
| S9 | OSDUIHelper `.volume`/`.mute` with chiclets on macOS 27 | Native OSD appears; otherwise plan a small house-style panel | Phase 0 |
| S7 | Bluetooth A2DP↔HFP switch mid-engine (AirPods, join a call) | `IsRunningOutput` and `Devices` stay correct; rate change detected | Phase 1 |
| S8 | Helper grouping coverage: Safari, Chrome, Edge, Firefox, Slack/Discord/VS Code (Electron), Music, Spotify, Zoom | Each maps to one correct row; record which lookup step resolved it | Phase 1 |
| S3 | R + app engine + R′ coexisting with the host-time crossfade; power | No blip or doubling over 20 toggles (ear + peak logs); `pmset -g assertions` clears after audio stops | Before Phase 2 |
| S4 | In-place `kAudioTapPropertyDescription` update adding a process | New process captured < 100 ms, no callback gap > 1 buffer, format unchanged, 100 clean runs | Before Phase 2 |
| S5 | `bundleIDs` + `processRestoreEnabled`: tap Safari, quit it, play in Mail, relaunch Safari | Safari restored, Mail not captured, tap survives zero processes | Before Phase 2 |

If S4 or S5 fail, the engine skips that feature (rebuild via crossfade instead; no restore). If S6 passes, mute without boost uses a bare muted tap (no aggregate, nothing to rebuild).

**Results (2026-10-06, TapLab scripted runs on macOS 27.0.1; numbers in `docs/LESSONS.md`):**
- **S1 pass.** Setup takes milliseconds and the aggregate is alive at once, so the readiness poll stays only as a safety net. The tap UID always matched the description. The gain ramp was measured, and you confirmed by ear that the app's own playback was replaced. Tapping an idle app gives no callbacks. Behaviour with permission denied is not tested yet (it needs a manual revoke).
- **S2 pass** on the Dell (HDMI). Only Dell-bound audio is captured, there is no feedback at gain 1.0, and default switches are handled. Open: the IOProc keeps running on silence once the device's other audio stops (fold into S3).
- **S6 pass.** The bare muted tap silences the app and `kill -9` restores it. Mute without boost will use a `muteOnly` engine.
- **S9: works, but draws the old OSD.** The modern top-right volume HUD can't be triggered by apps, so `VolumeHUDService` becomes a small FreeAudio panel in the modern style (Phase 4) and the OSDUIHelper code goes away.
- **Still to run:** S3, S4, S5 (need new TapLab code), S7 (AirPods in a call), S8 (needs Safari, Chrome, an Electron app, Spotify and Zoom playing).

## Phases

Test on real hardware after each phase. Build with `./scripts/build-app-clt.sh`, run `./scripts/test.sh`, and check logs with `log stream --predicate 'subsystem == "com.freeaudio.app"'`.

### Phase 0: housekeeping, strip, toolchain (spikes S1, S2, S6, S9 in parallel)

1. `git init` and a baseline commit ("Baseline: copy of FreeDisplay v2.2 with FreeAudio identity"). Ask before creating the GitHub repo.
2. Save this plan as `docs/ROADMAP.md`. Update `docs/FREEAUDIO_BRIEF.md` (decisions table; the macOS 27 floor; drop the "Atomic needs macOS 15" note), `CLAUDE.md` (macOS 27, arm64, FineTune GPL rule, recorded private-API approvals, `swift test`, XcodeGen), `README.md` (requirements: macOS 27, Apple silicon) and `AGENTS.md`.
3. Remove the display code listed in brief §4: services, models, views, `Utilities/NSScreenExtension.swift`, the bridging header (drop it from `project.yml` and `build-app-clt.sh`; nothing needs it now), the empty duplicate `FreeAudio/Resources/Assets.xcassets`, and `NSScreenCaptureUsageDescription`. Also remove `DDCService`, `PresetService`, `PresetListView` and `SavePresetView` for now; Phase 5 restores their patterns from the baseline commit.
4. Rename and trim what stays: `BrightnessKeyService` → `VolumeKeyService` (not started until Phase 4), `BrightnessHUDService` → `VolumeHUDService`. In `SettingsService`, drop the display members, stub the migration and fix the `fd.language` comment. `AppDelegate` drops all display services. `MenuBarView` keeps Settings, the update notice and the footer, drops the combined-brightness toggle, and calls `windowResizeAnchor(.top)` unconditionally. Menu bar symbol: `speaker.wave.2.fill`.
5. `project.yml`: deployment target 27.0 in both places, plus `NSAudioCaptureUsageDescription` (bilingual: "FreeAudio, uygulamaların ses düzeyini ayarlamak için sistem sesine erişir. / FreeAudio needs system audio access to control each app's volume."). `build-app-clt.sh`: `MIN_MACOS=27.0`, default `ARCHS=arm64`, the same plist key. `build-dmg.sh`: arm64 only.
6. `brew install xcodegen`, `xcodegen generate`; check the file list matches.
7. `Package.swift` (target `FreeAudioCore` at `FreeAudio/Core`, test target `Tests/FreeAudioCoreTests`) with one trivial test; confirm `./scripts/test.sh` runs on the CLT (it adds the Testing macro plugin path the CLT needs).
8. Optional but recommended: let `build-app-clt.sh` sign with `$CODESIGN_IDENTITY` when set (a self-signed "FreeAudio Dev" certificate). Ad-hoc signatures change every build, which resets the System Audio Recording and Accessibility grants each time.
9. `Spikes/TapLab`: a tiny app with its own `Info.plist` (`NSAudioCaptureUsageDescription`), bundle ID `com.freeaudio.taplab` and build script, outside `project.yml` and the app build. Run S1, S2, S6, S9.

**Check:** the app launches next to the running FreeDisplay with no effect on it (displays, gamma, brightness keys unchanged). The panel shows Settings and the footer. `./scripts/test.sh` passes. Spike results are written up.

### Phase 1: read-only listing (spikes S7, S8)

1. `Audio/CoreAudio+Extensions.swift`: thin additions to the Swift Core Audio API for what it lacks (`VirtualMainVolume`, mute, `IOProcStreamUsage`), and a listener bridge from `PropertyListenerDelegate` to the main actor with safe removal.
2. `DeviceService`: devices, default and system output, set default (also move the system output if it matched the old default), 50 ms debounce, Bluetooth re-read.
3. `DeviceVolumeService` (hardware tier): tier detection, `VirtualMainVolume` and mute read/write and listeners. Software-tier devices show an orange "Software" dot and a disabled slider until Phase 4.
4. `AppAudioService` plus `Core/AppGrouping.swift` (pure, with injected lookups): the grouping chain from "Do differently" (responsibility → outermost `.app` → own bundle → parent walk); exclusions (own PID, coreaudiod, systemsoundserverd, dictation and Siri daemons). Icons come from `NSRunningApplication`.
5. `Models/AudioApp`, `Models/AudioDevice`. Views: `OutputDeviceRow`, `DeviceListView`, `VolumeSliderRow` (built from `BrightnessSliderView`), read-only `AppVolumeRow`, empty state.
6. Write `docs/ARCHITECTURE.md` (format of `docs/reference/FreeDisplay-ARCHITECTURE.md`).

**Check:** rows appear and disappear within ~2 s for Music, Safari and Chrome. Safari's WebKit audio sits under Safari. Switching output in FreeAudio and in System Settings stays in sync. Hardware volume and mute work on the built-in speakers and AirPods. S7 and S8 are recorded.

### Phase 2: per-app volume (spikes S3, S4, S5 first)

1. Core: `VolumeCurve`, `RenderKernel`, `SoftLimiter`, `OutputGate`, `EngineDiff`, `AppSetting`, each with tests.
2. Audio: `RealtimeState`, `HALQueue`, `TapEngine` (`app` kind; the `rest` kind is built and tested but switched on in Phase 4), `PrivateAPI` (dlsym wrappers).
3. `TapService` reconciler with the lifetime rules, helper updates (S4 path or crossfaded rebuild), the IOProcStreamUsage write, a 20 ms mute ramp (or S6 muted tap), and boost with the limiter.
4. `PermissionService`: preflight before any tap is created. When denied, create no taps and show `PermissionRow` (opens `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture`; verify on 27). Safety net: if no engine has ever delivered non-zero audio and an engine sees only zeros for 2 s while its app runs output, tear everything down and show the row.
5. `SettingsService`: `apps.json` with debounce and flush. Settings is re-applied when an app appears again.
6. UI: interactive `AppVolumeRow`, `AppDetailView` (boost Off/150/200, reset), badges, the saved-settings list in Settings.
7. Diagnostics: an `os.Logger` "engine" category; the first-callback layout snapshot logged from main.

**Check:** Spotify at 30% is quieter while Safari is unaffected. Back at 100% and idle, the tap disappears. Opening a new Chrome tab while Chrome is at 30% is also attenuated. The first-run permission prompt appears; denying shows the row and leaves apps audible. Three controlled apps keep CPU low (Activity Monitor). `kill -9` of FreeAudio leaves every app audible.

### Phase 3: robustness

1. Reconciler triggers: default output change, an app's `Devices` change, sample-rate change on any engine device (150 ms debounce, ignore 0), device gone (tear down, fall back to default), `kAudioHardwarePropertyServiceRestarted` (rebuild all), wake (+1.5 s), app quit and relaunch (30 s grace).
2. Health watchdog: an app that is running output with no callbacks for 3×2 s gets rebuilt, with a 20 s cooldown. After 3 failures the row shows a warning.
3. Conflict notice: if another tap-based app is running (FineTune, SoundSource, MonitorKeys, eqMac, Background Music), show a row; taps from different processes interfere.
4. Quit: synchronous teardown of all engines with a 2 s cap. Launch: sweep leftover aggregates. Add a signal-handler cleanup only if the kill tests show stuck audio.

**Check:** switch between speakers, AirPods and the Dell while audio plays; join a call on AirPods; sleep and wake; force-quit and reopen a controlled app; `sudo killall coreaudiod`; plug and unplug a USB DAC. Audio is never stuck muted, even after `kill -9`.

Phases 3 and 4 can swap if you want the Dell working day to day sooner; the crossfade from Phase 2 is the only prerequisite.

### Phase 4: software volume and volume keys

1. `DeviceVolumeService` software tier: `devices.json`, x² curve, "Use software volume" override toggle in the device detail, and FreeAudio's own sounds scaled by hand.
2. Switch on the `rest` engine with the ownership-invariant crossfade (S3). It exists while the device is software tier and below 100% or muted, with 2 s hysteresis.
3. `VolumeKeyService`: the event tap from `BrightnessKeyService.swift` with media-key decoding (`Core/MediaKeyDecoder`). Consume keys only when the default output is software tier; otherwise pass them through so macOS behaves natively. Step 1/16, Option+Shift for 1/64, repeats handled, volume-up unmutes. Re-enable on `tapDisabledByTimeout`, re-check after wake, show Accessibility status in Settings with a button to the pane.
4. `VolumeHUDService`: a non-activating panel at the top right in the style of the macOS 26/27 volume HUD (icon, device name, level bar), shown on the screen with the menu bar, fading after ~1.5 s. It replaces the OSDUIHelper code, which only draws the old centered OSD (S9). Optional: feedback pop honouring `com.apple.sound.beep.feedback`.

**Check:** with the Dell as output, keys and slider change volume, show the OSD, and system alert sounds follow the level. On built-in speakers the keys behave exactly like macOS. FreeDisplay's brightness keys keep working with both event taps installed.

### Phase 5: extras (routing first; ask for the rest of the order)

1. **Per-app output routing:** an output picker in `AppDetailView` ("Sistem varsayılanı / System default" plus devices), `AppSetting.outputDeviceUID` by UID. A routed app is a controlled app, so it is already excluded from R and gets an engine on its device, with that device's software gain applied when it has one. A missing device means follow the default until it reconnects.
2. Profiles (restore the `PresetService` pattern from the baseline commit), per-app EQ (10-band biquad via vDSP, coefficient swap with deferred free), input device and level, optional DDC speaker volume (VCP 0x62, restore the `DDCService` core).

### Phase 6: release

New icon (`scripts/generate-icon.py` audio variant). README in FreeDisplay's structure with the "What does this replace" table against SoundSource, a troubleshooting note (leave calling apps at 100%; tapping breaks echo cancellation), and credits naming FineTune, AudioCap, Mimir and MonitorKeys as design references. `CHANGELOG.md` v1.0, final `ARCHITECTURE.md` and `LESSONS.md`. `./scripts/release.sh` after asking before creating and pushing `hakanotal/FreeAudio`. CI is optional (a GitHub runner with the macOS 27 SDK may not exist yet).

## Testing

**Swift Testing (pure logic):** the volume curve round-trip; the render kernel (trailing-buffer mapping, 2→N preferred pair, mono duplication, ramp reaching 99% in ~140 ms at 48 kHz, gate behaviour, limiter never above 1.0, crossfade keeping the rest level constant); `AppGrouping` with fake process tables; `EngineDiff` including the ownership invariant; Codable tolerance of `AppSetting` and `DeviceSetting`; the media-key decoder; the tier decision.

**Hardware matrix:**

| Device | Checks |
|---|---|
| Built-in speakers | Hardware volume, keys pass through, per-app gain |
| AirPods | Connect/disconnect while playing, HFP call mode, drift compensation off (no crackle) |
| Dell over USB-C (HDMI/DP) | Software volume, rest tap, keys + OSD, alert sounds |
| USB DAC or duplex interface | No microphone indicator, trailing-buffer mapping |
| BlackHole or another virtual device | Listed, no drift compensation, no crash |

## Risks

- A macOS 27 floor limits reach to macOS 27 users; it can be lowered to 26 later, since the newest tap APIs used are from 26.
- Tap behaviours are partly undocumented (stream indices, UID reassignment, in-place updates); the spikes exist for this.
- The private APIs may change; the dlsym fallbacks keep the app working with weaker grouping and permission detection.
- Calling apps lose echo cancellation while tapped, and only one tap-based app should run per machine.

## Critical files

- Modify: `project.yml`, `scripts/build-app-clt.sh`, `scripts/build-dmg.sh`, `FreeAudio/App/AppDelegate.swift`, `FreeAudio/App/FreeAudioApp.swift`, `FreeAudio/Views/MenuBarView.swift`, `FreeAudio/Services/SettingsService.swift`, `CLAUDE.md`, `docs/FREEAUDIO_BRIEF.md`, `docs/LESSONS.md`, `README.md`, `CHANGELOG.md`.
- Reuse: `MenuItemIcon`, `ExpandableRow`, footer and `SettingsView` (`Views/MenuBarView.swift`); the slider pattern (`Views/BrightnessSliderView.swift`); `L()`, `LanguageStore`, `save/load` (`Services/SettingsService.swift`); the event tap (`Services/BrightnessKeyService.swift`); the OSD XPC (`Services/BrightnessHUDService.swift`); `runWithTimeout` (`Services/CGHelpers.swift`); `LaunchService`, `UpdateService`, the single-instance and launchd hand-off in `AppDelegate`.
- New: everything under `FreeAudio/Core`, `FreeAudio/Audio`, the new services and views above, `Package.swift`, `Tests/`, `Spikes/TapLab`, `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`.

## Verification (end to end)

Each phase ends with: `./scripts/build-app-clt.sh` succeeds; `./scripts/test.sh` passes; `xcodegen generate` leaves the project in sync; the phase's hardware checks pass with FreeDisplay running; engine logs show no errors; `pmset -g assertions` shows no lingering audio assertion after playback stops; `kill -9` leaves all audio audible. Update `CHANGELOG.md` for user-visible changes, `docs/LESSONS.md` for new pitfalls and `docs/ARCHITECTURE.md` for new services.

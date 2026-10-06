# FreeAudio: project brief

FreeAudio will be a free, open-source macOS menu bar app for per-app audio control, an alternative to Rogue Amoeba's SoundSource. It comes from the same author as [FreeDisplay](https://github.com/hakanotal/FreeDisplay), a free BetterDisplay alternative. It should reuse FreeDisplay's know-how and look like FreeDisplay's sibling.

This folder starts as a copy of FreeDisplay v2.2 (commit `ae8f045`) with a new identity. The display code is still in it. This brief tells you what to keep, what to remove, how per-app audio works on current macOS, and in what order to build it.

Read this file first, then [`CLAUDE.md`](../CLAUDE.md) and [`docs/LESSONS.md`](LESSONS.md).

> **Update 2026-10-06:** the open questions are answered and the plan is now [`docs/ROADMAP.md`](ROADMAP.md), which wins where the two differ. Key changes: minimum macOS **27** (Apple silicon only, arm64 builds), FineTune (GPLv3) studied as a design reference only, the private responsibility and TCC preflight APIs approved, boost up to 200%, Swift Testing for pure logic, and per-app routing as the first post-MVP feature. This brief stays as background for the Core Audio approach and the style guide.

## 1. Current state of this folder

What was done during preparation:

- **Copied:** everything from FreeDisplay except its git history and build output. There is **no git repository yet**.
- **New identity, applied everywhere** (project, scripts, Xcode project, Swift code):

  | | Value |
  |---|---|
  | App name, module, scheme | `FreeAudio` |
  | Bundle ID | `com.freeaudio.app` |
  | Launch-at-login agent | `com.freeaudio.app.agent` |
  | Version / build | `0.1` / `1` |
  | UserDefaults key prefix | `fa.` (was `fd.`) |
  | Application Support folder | `FreeAudio` |
  | Update check repo | `hakanotal/FreeAudio` (doesn't exist yet; the check fails silently) |

  This keeps the two apps fully separate. With FreeDisplay's bundle ID, the single-instance check would quit the other app, and the two would share settings and the login agent.
- **Builds:** `ARCHS=arm64 ./scripts/build-app-clt.sh` produces `build/FreeAudio.app`. The Xcode project's file list matches the sources.
- **Docs:** FreeDisplay's architecture doc and screenshots moved to `docs/reference/` as references for patterns and visual style. `docs/LESSONS.md` is kept, because most of its Swift, SwiftUI, MenuBarExtra and build lessons apply here too.

~~Do not run the app yet.~~ Done in Phase 0: the display code is stripped, so the app runs next to FreeDisplay without touching displays.

## 2. Product scope

**MVP (the first release, v1.0):**

1. **App list:** shows the apps currently playing audio, with app icon and name. Helper processes are grouped under their app (browsers, Electron and WebKit play through helpers).
2. **Per-app volume** from 0 to 100%, with an optional boost up to 200%, plus per-app mute. Settings are remembered per app by bundle ID.
3. **Output device:** shows the default output device, lets the user switch it, and controls its volume and mute.
4. **Software volume for outputs with no hardware volume control.** HDMI and DisplayPort monitors are the main case; macOS greys out their volume. The author's own Dell, attached through a USB-C dongle, is one.
5. **Volume keys:** handled with the native macOS OSD when FreeAudio has to do the volume itself (the case in item 4).
6. The same shell as FreeDisplay: launch at login with crash restart, Turkish and English UI, update check, settings section.

**Later:**

- per-app output device routing;
- per-app EQ (10-band) and balance;
- input device selection and input level;
- profiles (save and apply a set of app volumes; reuse FreeDisplay's preset pattern);
- level meters;
- speaker volume of DDC monitors over VCP `0x62`, reusing FreeDisplay's DDCService (optional).

**Non-goals:** a virtual audio driver (HAL plug-in, as Background Music and eqMac use), recording, and Audio Unit hosting. Process taps make a driver unnecessary on macOS 14.2+. Ask the user before changing any of this.

## 3. How per-app audio works on macOS (Core Audio process taps)

Since **macOS 14.2**, Core Audio can tap the output of specific processes, mute their normal playback, and hand their audio to your own IOProc. You then play it to an output device at whatever gain you like. This is the public, supported approach. Mimir, FineTune, SonicFlow and AudioCap all use it.

API names below were checked against the macOS SDK headers on the build machine (`CoreAudio.framework/Headers/CATapDescription.h`, `AudioHardwareTapping.h`, `AudioHardware.h`).

### APIs

**Process objects.** Core Audio identifies clients by `AudioObjectID`, not by PID.
- `kAudioHardwarePropertyProcessObjectList` (`'prs#'`) on `kAudioObjectSystemObject` lists all audio client processes.
- `kAudioHardwarePropertyTranslatePIDToProcessObject` (`'id2p'`) maps a PID to its process object.
- Per-process properties:
  - `kAudioProcessPropertyPID`
  - `kAudioProcessPropertyBundleID` (a CFString you must release)
  - `kAudioProcessPropertyDevices` (output scope gives the output devices)
  - `kAudioProcessPropertyIsRunning`
  - `kAudioProcessPropertyIsRunningOutput` (`'piro'`, "has an active output stream", not "is audible")

**Taps.**
- `AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID* outTapID)` and `AudioHardwareDestroyProcessTap(AudioObjectID)`. Both need macOS 14.2.
- `CATapDescription` initialisers:
  - `initStereoMixdownOfProcesses:` (the one to use per app)
  - `initStereoGlobalTapButExcludeProcesses:` (use it for whole-system software volume; exclude FreeAudio's own process)
  - mono variants
  - `initWithProcesses:andDeviceUID:withStream:`
- `CATapDescription` properties:
  - `name`, `UUID`, `processes`, `mono`, `exclusive`, `mixdown`
  - `privateTap` (`isPrivate`; set it, so only FreeAudio sees the tap)
  - `muteBehavior`: `CATapUnmuted`, `CATapMuted`, or `CATapMutedWhenTapped`. Use `CATapMutedWhenTapped` so the app's normal playback is silenced while FreeAudio plays it instead.
  - New in **macOS 26**: `bundleIDs` and `processRestoreEnabled`. A tap can then follow an app by bundle ID across restarts. Available at the macOS 27 target; the roadmap's spike S5 decides whether to use them (never with bundle IDs shared by several apps, such as `com.apple.WebKit.GPU`).
- `kAudioTapPropertyFormat` (`'tfmt'`) gives the tap's `AudioStreamBasicDescription`. `kAudioTapPropertyUID` gives the UID for the aggregate device.

**Aggregate device**, created with `AudioHardwareCreateAggregateDevice` and destroyed with `AudioHardwareDestroyAggregateDevice`. It combines the tap (input) with the real output device. Dictionary keys:
- `kAudioAggregateDeviceUIDKey`, `kAudioAggregateDeviceNameKey`
- `kAudioAggregateDeviceIsPrivateKey` (true)
- `kAudioAggregateDeviceMainSubDeviceKey` (the output device's UID)
- `kAudioAggregateDeviceSubDeviceListKey` (the output device)
- `kAudioAggregateDeviceTapListKey`: an array of dictionaries, each with `kAudioSubTapUIDKey` (the tap UID) and `kAudioSubTapDriftCompensationKey` (true)
- `kAudioAggregateDeviceTapAutoStartKey`

**IO.** Create an IOProc with `AudioDeviceCreateIOProcIDWithBlock` on the aggregate device, then call `AudioDeviceStart`. The IOProc copies the tap input buffers to the output buffers, multiplied by a ramped gain.

**Device-level volume.**
- Read and write `kAudioDevicePropertyVolumeScalar` and `kAudioDevicePropertyMute` (main element, or per channel).
- Or use `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` and `..._VirtualMainBalance` from AudioToolbox's `AudioHardwareService`, which handles devices that only have per-channel volume.
- For the default device, use `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioHardwarePropertyDefaultSystemOutputDevice`.
- Watch everything with `AudioObjectAddPropertyListenerBlock`.

### Recommended design

- **Tap only what needs it.** Apps at 100%, not muted and not rerouted are left alone. A tap and aggregate device exist only for apps with a non-default setting. That means less CPU, no added latency for most apps, and fewer failure modes. When an app returns to defaults, destroy its tap.
- **One tap and one aggregate device per controlled app.** Key them by bundle ID, so all of an app's helper processes go into the same tap's `processes`.
- **Software device volume:** one global tap that excludes FreeAudio's own process (`initStereoGlobalTapButExcludeProcesses`), feeding the output device at the software volume. A device-specific setting (`deviceUID` on the description) is worth evaluating. Before building it, check how it interacts with the per-app taps; one combined graph may be cleaner than stacked taps.
- **Real-time rules inside the IOProc:**
  - no allocation, no locks, no Objective-C or Swift runtime calls that can allocate, no logging, no `@MainActor` work;
  - read the gain from a preallocated `UnsafeMutablePointer<Float>` that the main thread writes (aligned word-sized stores);
  - ramp gain changes over about 30 ms per sample to avoid clicks: `coef = 1 - exp(-1 / (sampleRate * 0.030))`;
  - With the macOS 27 target, use `Synchronization.Atomic` for the shared values.

### Permissions

- Add `NSAudioCaptureUsageDescription` to the Info.plist, in Turkish and English the way the app's other strings are. Xcode has no `INFOPLIST_KEY_` for it, so add it to the Info.plist template in `scripts/build-app-clt.sh` and to `project.yml` (as an `info:` plist section or an Info.plist file).
- On first tap creation macOS shows the **"System Audio Recording Only"** permission prompt. It is managed under *System Settings → Privacy & Security → Screen & System Audio Recording*.
- There is no public API to check or request this permission in advance. AudioCap uses private TCC calls; the user approved `TCCAccessPreflight`/`TCCAccessRequest` (2026-10-06), loaded with `dlsym`. Keep these fallbacks for when it is missing:
  - treat tap creation errors as "no permission";
  - also treat all-zero buffers while the app is playing as "no permission";
  - show a row explaining the problem, with a button that opens that settings pane.
- **Accessibility** is only needed for the volume-key event tap. This is the same as FreeDisplay's brightness keys.
- The app stays unsandboxed, like FreeDisplay.

### Known pitfalls (from Apple forums and the reference projects)

- **Aggregate device not ready:** it isn't usable the instant `AudioHardwareCreateAggregateDevice` returns. Wait or poll (for example `kAudioDevicePropertyDeviceIsAlive`) before starting the IOProc; otherwise you get silent failures.
- **Default output changes** (headphones plugged in, AirPods connecting): rebuild every tap and aggregate device against the new device, then restore gains.
- **Sample-rate or format changes** (`kAudioDevicePropertyNominalSampleRate`, or Bluetooth switching to the low-quality call profile when a mic opens): rebuild.
- **Sleep and wake:** rebuild after wake. Use FreeDisplay's `AppDelegate` sleep/wake wiring.
- **Unreliable listeners:** listeners for `kAudioProcessPropertyIsRunningOutput` don't always fire. Keep a 1–2 s poll of the process list as a backstop while the panel is open, and a slower one otherwise.
- **Callbacks only during playback:** taps deliver IOProc callbacks only while the app renders audio. Silence doesn't mean the tap is broken.
- **Taps from different processes on the same device interfere** (`AudioDeviceStart` can block until the other tap is torn down). FreeDisplay must never tap audio, and only one FreeAudio instance may run.
- **Helper processes:** Safari and WebKit use `com.apple.WebKit.GPU`; Chrome, Edge, Electron and Discord use "Helper (Renderer)" and "(GPU)". To group a helper under its app, map it to the `.app` bundle that contains its executable, or walk the bundle ID prefix. Show one row per app.
- **Own process:** never tap FreeAudio itself. Exclude it from the global tap.
- **Cleanup:** destroy taps and aggregate devices on quit. Private ones also disappear if the process dies, but never leave public ones behind.
- **Blocking calls:** HAL calls can block. Wrap setup and teardown the way FreeDisplay wraps WindowServer calls (`CGHelpers.runWithTimeout`); keep the IOProc itself free of that.

## 4. What to reuse from FreeDisplay

**Keep (and adapt names):**

| File | Use in FreeAudio |
|---|---|
| `App/FreeAudioApp.swift` | `MenuBarExtra(.window)` scene with `.windowResizability(.contentSize)`. Change the menu bar symbol (e.g. `speaker.wave.2.fill`). |
| `App/AppDelegate.swift` | Single-instance check, launchd hand-off (waits for the replaced instance), sleep/wake observers. Owns the main manager. Replace `DisplayManager` with `AudioManager`. |
| `Services/LaunchService.swift` | Launch at login through a per-user launchd agent with crash restart. Use as is. |
| `Services/SettingsService.swift` | `L("Türkçe", "English")`, `LanguageStore`, JSON persistence, versioned migration pattern. Remove the display members and FreeDisplay's `migrateLegacyDefaults` body. |
| `Services/UpdateService.swift` | GitHub release check. Use as is once the repo exists. |
| `Services/CGHelpers.swift` | `runWithTimeout` for blocking system calls. Rename if it becomes HAL-specific. |
| `Services/BrightnessKeyService.swift` | Becomes `VolumeKeyService`. Same event tap and NX media-key decoding, with `NX_KEYTYPE_SOUND_UP = 0`, `NX_KEYTYPE_SOUND_DOWN = 1`, `NX_KEYTYPE_MUTE = 7`. Consume keys only when FreeAudio must handle them (software-volume device); otherwise pass through. |
| `Services/BrightnessHUDService.swift` | Becomes the volume OSD through `com.apple.OSDUIHelper`. `OSDImage.volume = 3` and `.mute = 4` are already declared. |
| `Services/PresetService.swift`, `Views/PresetListView.swift`, `Views/SavePresetView.swift` | Profiles (later phase). |
| `Views/MenuBarView.swift` | `MenuItemIcon`, `ExpandableRow`, the row/expand pattern of `DisplayRowView`, the macOS 27 panel-height workaround, the footer, `SettingsView`. |
| `Views/BrightnessSliderView.swift` | Slider row pattern for per-app and device volume (icons, value label, highlight after release, DDC/Software status dot). |
| `Views/NightModeView.swift` | Example of a small segmented control plus slider section in house style. Delete once a FreeAudio view uses the pattern. |
| `scripts/build-app-clt.sh`, `build-dmg.sh`, `release.sh` | Build without Xcode, universal DMG plus SHA-256, GitHub release with notes from `CHANGELOG.md`. |
| `scripts/generate-icon.py` | Icon generator. Make an audio variant of FreeDisplay's icon in the same style. |

**Remove (display-only):**
- Services: `ArrangementService`, `AutoBrightnessService`, `BrightnessService`, `ColorProfileService`, `DisplayManager`, `GammaService`, `HiDPIService`, `NightModeService`, `NotchOverlayManager`, `ResolutionService`, `VirtualDisplayService`, and `DDCService` (unless you do the optional DDC speaker volume; then keep it and drop everything but the read/write core).
- Models: `ArrangementLayout`, `DisplayInfo`, `DisplayMode`; rework `DisplayPreset` into a profile model.
- Views: `ArrangementView`, `AutoBrightnessView`, `ColorProfileView`, `DisplayDetailView`, `DisplayModeListView`, `HiDPIView`, `ImageAdjustmentView`, `MainDisplayView`, `NightModeView` (after borrowing its pattern), `NotchView`, `VirtualDisplayView`.
- `FreeAudio-Bridging-Header.h`: process taps need no private declarations (`CATapDescription` is public Objective-C in CoreAudio). Empty it or drop the bridging header from `project.yml` and the build script.
- Info.plist: `NSScreenCaptureUsageDescription` (left over from FreeDisplay; not needed).

## 5. Visual style (keep it consistent with FreeDisplay)

See `docs/reference/FreeDisplay-Screenshot-1.png` to `-3.png` and the code in `Views/MenuBarView.swift`.

**Panel.**
- `MenuBarExtra` window style, 340 pt wide, 8 pt vertical padding.
- The scroll area's height is pinned to the measured content height, capped at 640. This is required on macOS 27 or the panel collapses.
- `.windowResizability(.contentSize)` so the panel shrinks again.

**Rows.**
- `MenuItemIcon`: a white SF Symbol (11 pt, semibold) on a 20×20 rounded square (radius 5) in a feature colour: blue for displays and devices, orange, indigo/purple, gray for Settings, green for Launch at login.
- Label in `.body`. Optional subtitle on the right in `.caption`, secondary colour.
- Expandable rows end with `chevron.right`, which rotates 90° (easeInOut, 0.2 s). Expansion uses `.spring(response: 0.3, dampingFraction: 0.8)` and transitions `.opacity.combined(with: .move(edge: .top))`.
- Padding: 12 pt horizontal, 7 pt vertical.
- Hover background `Color.primary.opacity(0.06)`.
- Rows with local state (hover, loading) are separate `struct`s named `XxxRow`.

**Sections.**
- Dividers at `.opacity(0.3)` with 2 pt vertical padding.
- Section headers like "Tools" in `.caption2`, semibold, secondary colour.
- Expanded content is indented: 8 pt leading for tools, 32 pt for detail panels (detail panels use a `controlBackgroundColor.opacity(0.4)` background).

**Controls.**
- Sliders get small leading and trailing SF Symbols (use `speaker.fill` / `speaker.wave.3.fill` instead of the suns).
- The value label is `.caption`, `.monospacedDigit()`, with a `.numericText()` transition. It flashes accent colour for 0.4 s after the user releases the slider.
- Status uses a coloured dot plus caption (green "DDC" or orange "Software" in FreeDisplay; use it for "Hardware" / "Software" volume).
- Badges are `.caption2` coloured text on `color.opacity(0.12)` with radius 3, like "Main" and "HiDPI" (use for "Muted", "Boost", device names).
- Toggles use `.switch` style, `.controlSize(.small)`, right-aligned. Pickers are segmented and small.

**Footer.** Pinned below the scroll area: "FreeAudio vX.Y" in `.caption`, medium weight, secondary colour, and a Quit button (`xmark` plus "Quit") that turns red on hover.

**Language.** Every visible string goes through `L("Türkçe", "English")`. Turkish is the default. Every control gets `.help(...)` and an accessibility label, as in FreeDisplay.

**Proposed main panel:**

```
┌──────────────────────────────────────────┐
│ [🔈] MacBook Pro Speakers        ▸        │  output device row: expands to device list
│      🔈 ───────●────────── 🔊   65%       │  device volume (Hardware/Software dot)
├──────────────────────────────────────────┤
│ Apps                                      │
│ [Spotify icon] Spotify     ──●──── 40% 🔇 │  one row per app playing audio
│ [Safari icon]  Safari      ──────● 100%   │  expand ▸ for output device, boost, EQ (later)
│ [Zoom icon]    zoom.us     ────●── 80%    │
├──────────────────────────────────────────┤
│ Tools                                     │
│ [🎚] Profiles                      ▸      │  later
│ [🎤] Input                         ▸      │  later
├──────────────────────────────────────────┤
│ [⚙] Settings                       ▸      │  language, launch at login, updates, permission status
├──────────────────────────────────────────┤
│ FreeAudio v0.1                    ✕ Quit  │
└──────────────────────────────────────────┘
```

App icons come from `NSRunningApplication(processIdentifier:)?.icon`, shown at 20×20 in place of `MenuItemIcon`.

## 6. Proposed architecture

Same layering as FreeDisplay: **Views → Services → system frameworks**. Services are `@MainActor final class … : ObservableObject, @unchecked Sendable` singletons. The main manager is owned by `AppDelegate`.

| Type | Responsibility |
|---|---|
| `AudioManager` (owned by `AppDelegate`) | Enumerates output devices and audio processes, groups helpers into apps, runs the listeners and the poll, and publishes `apps` and `devices`. |
| `AudioApp` (model, `ObservableObject`) | `bundleID`, name, icon, process object IDs and PIDs, `volume`, `isMuted`, `isPlaying`, later `outputDeviceUID`. |
| `AudioDevice` (model) | `AudioObjectID`, UID, name, transport type, whether hardware volume exists, volume, mute. |
| `AppTapEngine` (not `@MainActor`) | One per controlled app: tap, aggregate device, IOProc, gain pointer. `start`, `stop`, `setGain`, `rebuild(outputDevice:)`. |
| `DeviceVolumeService` | Hardware volume and mute; the software path via the global tap for devices without volume. |
| `VolumeKeyService`, `VolumeHUDService` | Adapted from the brightness equivalents. |
| `SettingsService` | Per-app settings keyed by **bundle ID**, never PID or `AudioObjectID` (they change every launch). This mirrors FreeDisplay's lesson to key by display UUID. |

## 7. Plan (phases with acceptance checks)

Test on real hardware after each phase. There is no automated test suite. Build with `ARCHS=arm64 ./scripts/build-app-clt.sh`. Quit the installed FreeDisplay while testing anything that touches keys.

**Phase 0: housekeeping and strip.**
- `git init` and a first commit, "Baseline: copy of FreeDisplay v2.2 with FreeAudio identity", so later diffs are reviewable.
- Ask the user before creating the GitHub repo (expected: `hakanotal/FreeAudio`).
- Remove the display code (section 4).
- Raise the deployment target to **27.0** (decided 2026-10-06; originally 14.2) in `project.yml` and `MIN_MACOS` in `build-app-clt.sh`.
- Add `NSAudioCaptureUsageDescription` and remove `NSScreenCaptureUsageDescription`.
- Trim the bridging header. Set the menu bar symbol.
- Update the Xcode project file list (`xcodegen generate` if it's installed; otherwise edit the pbxproj carefully, as was done for FreeDisplay v2.2).
- **Check:** the app launches next to FreeDisplay without affecting it (displays, gamma and brightness keys unchanged). The panel shows Settings and the footer.

**Phase 1: read-only listing.**
- Output devices (default plus list, switching the default) and device volume and mute through hardware properties.
- Apps playing audio, with icons, helpers grouped, updating live.
- **Check:** start and stop audio in Music, Safari and Chrome; rows appear and disappear within about 2 s. Switching the output in FreeAudio and in System Settings stays in sync.

**Phase 2: per-app volume.**
- Taps plus aggregate devices for apps with non-default settings, ramped gain, mute, boost up to 200%.
- Settings persisted by bundle ID and re-applied when the app plays again.
- Permission handling (section 3).
- **Check:** Spotify at 30% is quieter while Safari is unaffected; returning to 100% removes the tap. The first-run permission prompt appears. Denying permission shows the guidance row, not a crash or silence. CPU use stays low with three controlled apps.

**Phase 3: robustness.**
- Rebuild on default-device change, sample-rate change, Bluetooth profile switch, sleep/wake, and app restart.
- Clean teardown on quit.
- **Check:** switching between speakers, AirPods and the HDMI monitor while audio plays; joining a call with AirPods; sleep and wake; force-quitting a controlled app and reopening it. Afterwards audio is never stuck muted, even if FreeAudio itself is killed.

**Phase 4: keys and software volume.**
- Software volume for devices with no hardware volume (HDMI/DisplayPort).
- Volume keys with the native OSD on those devices.
- **Check:** with the HDMI monitor as output, the keys and slider change volume and show the OSD. On the built-in speakers, keys still behave exactly like macOS.

**Phase 5: extras.** Per-app output routing, EQ, profiles, input device, optional DDC speaker volume. Ask the user for priorities first.

**Phase 6: release.**
- New icon.
- README rewrite: use FreeDisplay's README structure and its "What does this replace" table, here against SoundSource.
- `CHANGELOG.md`.
- `./scripts/release.sh` to publish the DMG on GitHub.

## 8. Rules carried over

- Every UI string goes through `L("Türkçe", "English")`.
- Views never call Core Audio directly; they go through a service.
- The IOProc is real-time code: no allocation, locks, logging or `@MainActor` hops.
- Persist per app by bundle ID and per device by device UID.
- Ask the user before:
  - adding private APIs (including the TCC preflight AudioCap uses);
  - adding third-party dependencies;
  - changing the minimum macOS (27);
  - creating or pushing to a GitHub repository.
- Keep `CHANGELOG.md`, `docs/LESSONS.md` and a FreeAudio `docs/ARCHITECTURE.md` current as you go. Write the architecture doc when Phase 1 lands, following the reference copy's format.

## 9. Open questions for the user

1. ~~Minimum macOS~~: **macOS 27** (answered 2026-10-06).
2. ~~Boost limit~~: **200%** (answered 2026-10-06).
3. ~~After the MVP~~: **per-app output routing** first (answered 2026-10-06).
4. App icon direction: an audio variant of the FreeDisplay icon? (Phase 6)
5. GitHub repository name and whether to publish it right away. (Ask before creating it.)

## 10. References

- Apple: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [AudioCap](https://github.com/insidegui/AudioCap): tap plus aggregate device sample, with notes on the permission key and the missing permission API
- [Mimir](https://github.com/ThalesBMC/Mimir) and its write-up [macOS still has no volume mixer, so I built one](https://dev.to/thalesbmc/macos-still-has-no-volume-mixer-so-i-built-one-53lp): per-app volume, readiness delay, ramping, device switching, helper processes
- [FineTune](https://github.com/ronitsingh10/FineTune): open-source per-app volume, routing and EQ menu bar app
- [SonicFlow](https://github.com/altuzar/sonic): minimal Swift 6 per-app volume app using process taps
- Apple Developer Forums:
  - [software volume for HDMI/DisplayPort via process taps](https://developer.apple.com/forums/thread/848578) (FB24965962; taps from different processes interfere);
  - [`kAudioProcessPropertyIsRunningOutput` listener not firing](https://developer.apple.com/forums/thread/770348);
  - [tap delivering all-zero buffers](https://developer.apple.com/forums/thread/825780).
- FreeDisplay: `docs/reference/FreeDisplay-ARCHITECTURE.md`, `docs/LESSONS.md`, and the [v2.2 release](https://github.com/hakanotal/FreeDisplay/releases/tag/v2.2)

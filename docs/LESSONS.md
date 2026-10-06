# Lessons Learned

Hard-won constraints. Each one cost real debugging time; don't relearn them.

> Most of these are inherited from FreeDisplay. The display-only lessons (HiDPI, gamma, arrangement, virtual displays, ColorSync) were removed with the display code in Phase 0; they are in the baseline commit's history. The DDC section stays for the optional monitor speaker volume (roadmap Phase 5).

## Audio

- Facts taken from FineTune and the Apple forums are listed in [ROADMAP.md](ROADMAP.md) under "What FineTune teaches". Move each one here once it is confirmed on our own hardware, and record every spike result (S1–S9) here.
- macOS 15+ has a Swift Core Audio object API (`AudioHardwareSystem.shared`, `AudioHardwareDevice`, `AudioHardwareProcess`, `AudioHardwareTap`, `AudioHardwareAggregateDevice`, `PropertyListenerDelegate`). Use it for discovery and setup instead of hand-rolled `AudioObjectGetPropertyData`; `VirtualMainVolume` still needs `import AudioToolbox`.
- `TCCAccessPreflight(kTCCServiceAudioCapture)` returns 2 before the user was ever asked (0 = authorized, 1 = denied). (TapLab, 2026-10-06)
- Helper grouping order: responsibility API, then the outermost `.app` in `proc_pidpath`, then the process's own bundle. Electron helpers can be `.app` bundles themselves (a Claude helper reported its own `bundleURL` ending in `.app`), so checking the own bundle first gives helpers their own rows. (TapLab, 2026-10-06)
- `com.apple.WebKit.GPU` belongs to whichever app embeds WebKit (Outlook on this machine, not just Safari). Never tap or exclude by that bundle ID. (TapLab, 2026-10-06)
- Spike results (TapLab, 2026-10-06, macOS 27.0.1, MacBook Pro speakers and a Dell S2721DGF over HDMI; details in the roadmap's spike table):
  - Tap creation takes 3–6 ms, aggregate creation 4–8 ms, the aggregate is alive immediately and `AudioDeviceStart` returns in ~0.1 ms. The tap's `kAudioTapPropertyUID` equaled the description's UUID every time.
  - A stereo-mixdown tap is 48 kHz, 2-channel, interleaved Float32. The IOProc gets one input buffer (the tap) and one output buffer, 512 frames, ~94 callbacks/s.
  - Tapping an idle process: start returns instantly and the IOProc gets no callbacks until the process plays.
  - An unmuted device-scoped tap still sees a process that another tap mutes. "Observer" taps can't prove muting, and the rest tap must exclude every controlled app explicitly.
  - A bare `CATapMuted` tap with no aggregate silences an app; destroying it, or `kill -9` of the owner, brings the audio back at once.
  - A device-scoped rest tap only captures audio bound for its device, doesn't recapture our own output when our process object (plus bundle ID) is excluded, and survives default-output switches without errors.
  - Once a running rest tap's device has no other audio, its IOProc keeps running on silence (~94 callbacks/s). Check power and CPU before keeping it alive (S3).
  - OSDUIHelper still works on macOS 27 but draws the old centered OSD. The modern volume HUD (top right) belongs to Control Center and can't be triggered by apps.
  - S4: setting `kAudioTapPropertyDescription` with a longer process list on a running tap takes ~7 ms, the new process is captured within ~30 ms, there is no callback gap longer than one buffer, and the format stays the same. 100 alternating updates: no failures.
  - S5: with `bundleIDs = [app]` and `processRestoreEnabled`, a tap follows the app across quit and relaunch (its process list goes empty, then holds the new process object) and ignores apps with other bundle IDs. A tap made with an empty process list and only `bundleIDs` picks the app up when it starts.
  - S3: handing a process from the rest tap to its own tap with linear crossfades scheduled in host time (each IOProc computes its gain per frame from its output timestamp) is clean by ear over 20 handovers. Aggregates on the same device do not share IO timestamps, so never match buffers by timestamp equality.
  - A tap whose processes are all silent gets no callbacks, so "wait for the first callback" is only a valid readiness check for an engine whose source is playing.
  - Power: once an aggregate's IO has started it keeps running after its source stops (~94 callbacks/s), and coreaudiod holds a `PreventUserIdleSystemSleep` assertion per running aggregate, so the Mac never idle-sleeps. `AudioDeviceStop` + `AudioDeviceStart` on the idle aggregate drops callbacks to 0 and releases the assertion while keeping tap and aggregate; `TapAutoStart` resumes IO when the source plays.
- A bare `.muted` tap with no aggregate (bundle IDs + `processRestoreEnabled` set, Zen's main process in `processes`) did not silence Zen, although the same tap kind silenced `afplay` in S6 (no bundle IDs). Cause not isolated. Mute is gain 0 on the regular engine instead, which is also instant and click-free (no tap rebuild on toggle). (2026-10-06)
- Phase 2 live test (2026-10-06): with the fast path, a controlled app's engine starts ~90 ms after its audio process appears (~350 ms with the earlier 100 + 150 ms debounces, audible as a loud start). Apps with saved settings get a pre-armed bundle-ID tap before they run, so normal apps are controlled from the first sample; plain executables (`afplay`) still get the ~90 ms gap. `kill -9` and a normal quit both return the app to full volume at once.
- Count an engine's silence from the first callback after its IO (re)started, not from creation or "never had sound": an app that just started, or a stream moving to another device, is silent for a few hundred ms, and a pre-armed engine may have sat idle for hours before its app starts. Getting this wrong restarted the IO in the middle of playback. (2026-10-06)
- Phase 3 automated tests (2026-10-06): after a default-output switch the engine moves to the new device ~40 ms later; a sample-rate change on the output (48 → 44.1 → 48 kHz) is detected after the 150 ms debounce and the engine is rebuilt at the new rate; an app quitting leaves its pre-armed engine idle, its IO is restarted 3 s later and coreaudiod's sleep assertion disappears.
- Core Audio reuses process object IDs after a process exits (three successive `afplay` PIDs all got object 123). Never cache an object ID beyond the process's lifetime.
- A process gets a Core Audio process object as soon as it talks to the HAL, before it plays anything, so FreeAudio can exclude its own object from taps from the start. Process objects also exist for idle apps (`isRunningOutput == false`). (TapLab, 2026-10-06)

## Permissions and signing

- macOS judges a process started from a terminal by the terminal app's grants (the responsible process). `FreeAudio --dump-audio` run from a shell reports Cursor's System Audio Recording status, not FreeAudio's. Launch with `open` for anything permission-related.
- Ad-hoc signatures change every build, and TCC drops the grant each time. A self-signed "FreeAudio Dev" code-signing certificate (imported with `security import … -T /usr/bin/codesign`; untrusted is fine) gives a designated requirement of `identifier "com.freeaudio.app" and certificate leaf = H"…"`, which is stable, so grants survive rebuilds. `build-app-clt.sh` uses it automatically; release builds stay ad-hoc.

## Private APIs

- Load private framework symbols with `dlopen` + `dlsym`. `@_silgen_name` compiles but fails to link.

## DDC / IOKit

- Validate DDC replies (opcode 0x02, result 0, VCP echo, checksum 0x50 ^ bytes 0…9). Unvalidated replies report bogus values.
- One failed DDC transfer isn't proof DDC is unsupported (monitor waking up). Re-probe after wake.
- IOFramebuffer I2C (`IOFBCopyI2CInterfaceForBus`) silently does nothing on Apple Silicon. Use IOAVService via `DCPAVServiceProxy`.
- Don't match IOKit services with `CGDisplayVendorNumber/ModelNumber`; they don't always match IOKit's IDs. Use `NSScreen.localizedName` for names.
- Integer values in IOKit CF dictionaries may bridge as `Int`, not `UInt32`. Try both.
- DDC reads take 50 ms or more. Cache them (5 s TTL), invalidate after writes, and degrade gracefully when DDC is unsupported.

## Shared resources & lifecycle

- Pass `self` to long-lived C callbacks with `Unmanaged.passRetained`, and `release()` on unregister.
- Lock mutable state that is read from multiple threads.
- Set `NSWindow.isReleasedWhenClosed = false` for windows you keep in a dictionary.
- Don't mutate a dictionary while iterating it; collect the keys first.
- Wrap blocking system calls in a timeout (`HALQueue.run`; FreeDisplay's `CGHelpers.runWithTimeout`). It returns on timeout, but the stuck call keeps running on its thread.
- The single-instance check must tolerate short-lived copies: an old instance that is still quitting, or a `--dump-audio` run, made a fresh launch exit at once. A manual launch now waits up to 2 s for other copies to go away.
- Event tap callbacks don't own the passed-in event: return `Unmanaged.passUnretained(event)` to pass it through. `passRetained` leaks one event per call.
- Swift 6 inserts a runtime main-thread check into closures created in a `@MainActor` context and passed as non-`@Sendable` parameters. If such a closure runs on another queue (DDC completions, XPC handlers, audio callbacks), the app traps. Mark completion handlers that run off-main `@Sendable`.

## SwiftUI / MenuBarExtra

- Custom content needs `.menuBarExtraStyle(.window)`. Hide the Dock icon with `INFOPLIST_KEY_LSUIElement: true`.
- MenuBarExtra content is built lazily and its `.task`/`.onAppear` run on every panel open. Launch, wake and one-time work belongs in `AppDelegate`, and singletons whose init starts work must be touched at launch.
- `NSWindow(contentRect:…, screen:)` treats the rect as relative to that screen. Pass global rects without `screen:`.
- On macOS 27 the panel is sized to the content's *minimum* size, so a bare `ScrollView` collapses to 0 height. Pin the scroll view to the measured content height.
- Row components with local state (`isHovered`, `isLoading`) must be separate `struct`s. `@ViewBuilder` functions can't hold `@State`.
- Observe shared singletons with `@ObservedObject`, not `@StateObject`.
- Don't make IOKit/CG/Core Audio calls in `body`; load them in `.task`/`onAppear` or a service.
- `flag = true; syncWork(); flag = false` never renders the intermediate state. Use async.

## Build

- After changing `project.yml` or adding files, run `xcodegen generate`.
- `GENERATE_INFOPLIST_FILE: YES` is required. Keys Xcode has no `INFOPLIST_KEY_` for (e.g. `NSAudioCaptureUsageDescription`) go in `project.yml` under `info: properties:`; XcodeGen writes them to `FreeAudio/Info.plist`. Map `CFBundleShortVersionString`/`CFBundleVersion` to `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` there, or the generated file pins them to 1.0/1.
- Swift 6 singletons: `@MainActor` + `@unchecked Sendable`, with `SWIFT_STRICT_CONCURRENCY: minimal`.
- `deinit` is nonisolated. Properties it touches need `nonisolated(unsafe)`.
- The Command Line Tools have no SwiftUI macro plugin (`build-app-clt.sh` shims `@State`), and keep the Swift Testing macro plugin in `usr/lib/swift/host/plugins/testing`, which `swift test` doesn't search. Run tests through `./scripts/test.sh`, which adds `-plugin-path`.
- `import IOKit` doesn't include I2C/graphics. Add `import IOKit.i2c` / `import IOKit.graphics`.

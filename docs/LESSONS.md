# Lessons Learned

Hard-won constraints. Each one cost real debugging time; don't relearn them.

> Most of these are inherited from FreeDisplay. The display-only lessons (HiDPI, gamma, arrangement, virtual displays, ColorSync) were removed with the display code in Phase 0; they are in the baseline commit's history. The DDC section stays for the optional monitor speaker volume (roadmap Phase 5).

## Audio

- Facts taken from FineTune and the Apple forums are listed in [ROADMAP.md](ROADMAP.md) under "What FineTune teaches". Move each one here once it is confirmed on our own hardware, and record every spike result (S1–S9) here.
- macOS 15+ has a Swift Core Audio object API (`AudioHardwareSystem.shared`, `AudioHardwareDevice`, `AudioHardwareProcess`, `AudioHardwareTap`, `AudioHardwareAggregateDevice`, `PropertyListenerDelegate`). Use it for discovery and setup instead of hand-rolled `AudioObjectGetPropertyData`; `VirtualMainVolume` still needs `import AudioToolbox`.
- `TCCAccessPreflight(kTCCServiceAudioCapture)` returns 2 before the user was ever asked (0 = authorized, 1 = denied). (TapLab, 2026-10-06)
- Helper grouping order: responsibility API, then the outermost `.app` in `proc_pidpath`, then the process's own bundle. Electron helpers can be `.app` bundles themselves (a Claude helper reported its own `bundleURL` ending in `.app`), so checking the own bundle first gives helpers their own rows. (TapLab, 2026-10-06)
- `com.apple.WebKit.GPU` belongs to whichever app embeds WebKit (Outlook on this machine, not just Safari). Never tap or exclude by that bundle ID. (TapLab, 2026-10-06)
- A process gets a Core Audio process object as soon as it talks to the HAL, before it plays anything, so FreeAudio can exclude its own object from taps from the start. Process objects also exist for idle apps (`isRunningOutput == false`). (TapLab, 2026-10-06)

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
- Wrap blocking system calls in a timeout (`CGHelpers.runWithTimeout`). It returns the fallback on timeout, but the stuck call keeps running on its thread.
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

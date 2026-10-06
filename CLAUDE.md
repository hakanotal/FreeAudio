# FreeAudio

Free, open-source SoundSource alternative: a macOS menu bar app for per-app volume and mute, output device control, software volume for outputs without hardware volume (HDMI/DisplayPort), and later per-app routing, EQ and profiles. UI in Turkish and English. Sibling of [FreeDisplay](https://github.com/hakanotal/FreeDisplay); same know-how, same visual style.

**Status:** Phases 0–2 of [docs/ROADMAP.md](docs/ROADMAP.md) are built (listing, device volume, per-app volume); Phase 3 (robustness) is next. **Start with the roadmap**: decisions, engine design, spikes, phases with acceptance checks. [docs/FREEAUDIO_BRIEF.md](docs/FREEAUDIO_BRIEF.md) keeps the background (Core Audio process taps, style guide); where the two differ, the roadmap wins.

Swift 6 + SwiftUI (`MenuBarExtra`) + Core Audio process taps. **Minimum macOS 27, Apple silicon only (arm64).** No third-party dependencies. App Sandbox is off.

- Plan, decisions and engine design: [docs/ROADMAP.md](docs/ROADMAP.md)
- Background and style guide: [docs/FREEAUDIO_BRIEF.md](docs/FREEAUDIO_BRIEF.md)
- Pitfalls: [docs/LESSONS.md](docs/LESSONS.md)
- FreeDisplay's architecture and screenshots (patterns and visual reference): [docs/reference/](docs/reference/)

## Build

```bash
./scripts/build-app-clt.sh   # local build → build/FreeAudio.app (no Xcode needed)
./scripts/test.sh            # Swift Testing unit tests for FreeAudio/Core (swift test on the CLT)
./scripts/build-dmg.sh       # release app + DMG in build/
xcodegen generate            # after adding/removing files or editing project.yml (XcodeGen is installed)
```

Unit tests cover pure logic only (`FreeAudio/Core`, compiled into both the app and `Package.swift`). Per-app audio, device switching and volume keys must be checked on real hardware (built-in speakers, AirPods, the Dell over USB-C, a USB DAC). `build-app-clt.sh` signs with the local self-signed "FreeAudio Dev" certificate when it exists, so System Audio Recording and Accessibility grants survive rebuilds (ad-hoc signatures change every build). Launch with `open`, not from a shell: a process started from a terminal is judged by the terminal's permissions.

## Language

- Code, comments, commit messages and docs: **English**.
- User-facing strings: inline Turkish/English pairs via `L("Türkçe", "English")` (defined in `SettingsService.swift`). Never hard-code a single-language UI string.

## Rules

**Reference code license**
- [FineTune](https://github.com/ronitsingh10/FineTune) is **GPLv3**; FreeAudio is MIT. It was studied as a design reference (summary in the roadmap's "What FineTune teaches"). Never copy its code or test fixtures, and never translate a file line by line. Write FreeAudio code from the roadmap, Apple's headers and FreeDisplay's patterns.

**Structure**
- Views never call Core Audio, CoreGraphics or IOKit directly; go through a Service.
- Services are `@MainActor final class … : ObservableObject, @unchecked Sendable` singletons (`static let shared`). The main manager is owned by `AppDelegate`.
- Pure, testable logic goes in `FreeAudio/Core` (Foundation and Core Audio types only; no AppKit, SwiftUI or services) with tests in `Tests/FreeAudioCoreTests`.
- Row components with local state (`isHovered`, `isLoading`) are separate `struct`s named `XxxRow`, not `@ViewBuilder` functions.
- UserDefaults keys always use the `fa.` prefix.
- Persist per-app settings by bundle ID and per-device settings by device UID. Never key saved state by PID or `AudioObjectID`; they change every launch.
- Concurrency errors: use `@MainActor` or `@unchecked Sendable` (`SWIFT_STRICT_CONCURRENCY: minimal`). Mark completion handlers and callbacks that run off-main `@Sendable` (Swift 6 traps otherwise).

**Audio**
- IOProcs are C functions (`AudioDeviceCreateIOProcID` + client-data pointer), not blocks. They are real-time code: no allocation, locks, logging, ARC, Objective-C/Swift runtime calls that can allocate, or `@MainActor` hops. Share state through preallocated memory and `Atomic`; ramp gain changes (~30 ms).
- Only tap apps whose settings differ from default; destroy taps and aggregate devices when no longer needed and on quit. Taps and aggregate devices are always private.
- Never tap FreeAudio's own process.
- Rebuild taps on default-output change, sample-rate/format change, coreaudiod restart and after wake.
- HAL setup/teardown runs on the serial HAL queue with a timeout (see the roadmap's engine design), never on the main thread.

**Approved by the user (2026-10-06):** minimum macOS 27; the private APIs `responsibility_get_pid_responsible_for_pid` and `TCCAccessPreflight`/`TCCAccessRequest` (loaded with `dlsym`, with a public fallback); XcodeGen as a dev-only tool.

**Ask the user first** before adding any other private API, anything that needs SIP off or special permissions beyond System Audio Recording and Accessibility, third-party dependencies, changing the minimum macOS, architecture changes beyond the roadmap, or creating/pushing a GitHub repository.

## Keeping docs current

- Added/removed a Service or changed a key flow → update `docs/ARCHITECTURE.md` (create it when Phase 1 lands; follow `docs/reference/FreeDisplay-ARCHITECTURE.md`).
- Hit a non-obvious pitfall → add one line to `docs/LESSONS.md`.
- User-visible change → add it to `CHANGELOG.md`.
- A roadmap decision changes → update `docs/ROADMAP.md`.

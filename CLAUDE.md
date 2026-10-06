# FreeAudio

Free, open-source SoundSource alternative: a macOS menu bar app for per-app volume and mute, output device control, software volume for outputs without hardware volume (HDMI/DisplayPort), and later per-app routing, EQ and profiles. UI in Turkish and English. Sibling of [FreeDisplay](https://github.com/hakanotal/FreeDisplay); same know-how, same visual style.

**Status:** the project was just created as a copy of FreeDisplay v2.2 with a new identity. It still contains FreeDisplay's display code. **Start with [docs/FREEAUDIO_BRIEF.md](docs/FREEAUDIO_BRIEF.md)**: scope, Core Audio process-tap approach, what to keep and remove, style guide, phased plan. Don't run the app before Phase 0 (strip display code) or it will fight the user's installed FreeDisplay.

Swift 6 + SwiftUI (`MenuBarExtra`) + Core Audio (process taps, macOS 14.2+). No third-party dependencies. App Sandbox is off.

- Plan and approach: [docs/FREEAUDIO_BRIEF.md](docs/FREEAUDIO_BRIEF.md)
- Pitfalls inherited from FreeDisplay: [docs/LESSONS.md](docs/LESSONS.md)
- FreeDisplay's architecture and screenshots (patterns and visual reference): [docs/reference/](docs/reference/)

## Build

```bash
ARCHS=arm64 ./scripts/build-app-clt.sh   # quick local build → build/FreeAudio.app (no Xcode needed)
./scripts/build-dmg.sh                   # universal release app + DMG in build/
xcodegen generate                        # after editing project.yml or adding files, if XcodeGen is installed
```

There is no automated test suite. Per-app audio, device switching and volume keys must be checked on real hardware (built-in speakers, Bluetooth headphones, an HDMI/DisplayPort monitor).

## Language

- Code, comments, commit messages and docs: **English**.
- User-facing strings: inline Turkish/English pairs via `L("Türkçe", "English")` (defined in `SettingsService.swift`). Never hard-code a single-language UI string.

## Rules

**Structure**
- Views never call Core Audio, CoreGraphics or IOKit directly; go through a Service.
- Services are `@MainActor final class … : ObservableObject, @unchecked Sendable` singletons (`static let shared`). The main manager is owned by `AppDelegate`.
- Row components with local state (`isHovered`, `isLoading`) are separate `struct`s named `XxxRow`, not `@ViewBuilder` functions.
- UserDefaults keys always use the `fa.` prefix.
- Persist per-app settings by bundle ID and per-device settings by device UID. Never key saved state by PID or `AudioObjectID`; they change every launch.
- Concurrency errors: use `@MainActor` or `@unchecked Sendable` (`SWIFT_STRICT_CONCURRENCY: minimal`). Mark completion handlers and callbacks that run off-main `@Sendable` (Swift 6 traps otherwise).

**Audio**
- IOProc blocks are real-time code: no allocation, locks, logging, Objective-C/Swift runtime calls that can allocate, or `@MainActor` hops. Share state through preallocated memory; ramp gain changes (~30 ms).
- Only tap apps whose settings differ from default; destroy taps and aggregate devices when no longer needed and on quit. Taps and aggregate devices are always private.
- Never tap FreeAudio's own process.
- Rebuild taps on default-output change, sample-rate/format change and after wake.
- Wrap potentially blocking HAL setup/teardown off the main thread with a timeout (pattern: `CGHelpers.runWithTimeout`).

**Ask the user first** before adding private APIs (including TCC permission preflight), anything that needs SIP off or special permissions beyond System Audio Recording and Accessibility, third-party dependencies, a minimum macOS above 14.2, architecture changes, or creating/pushing a GitHub repository.

## Keeping docs current

- Added/removed a Service or changed a key flow → update `docs/ARCHITECTURE.md` (create it when Phase 1 lands; follow `docs/reference/FreeDisplay-ARCHITECTURE.md`).
- Hit a non-obvious pitfall → add one line to `docs/LESSONS.md`.
- User-visible change → add it to `CHANGELOG.md`.

import AppKit
import CoreGraphics

// MARK: - C Event Tap Callback

/// Global C callback for the CGEventTap. `userInfo` carries an Unmanaged<VolumeKeyService>.
/// The tap is registered on the main run loop, so this callback always fires on the main thread.
private func volumeKeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<VolumeKeyService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handleEventFromCallback(type: type, event: event)
}

// MARK: - VolumeKeyService

/// Intercepts the macOS volume keys. A key is consumed only when `handler` returns true for it
/// (FreeAudio drives the volume itself, e.g. on an output without hardware volume); everything
/// else passes through so macOS keeps its native behaviour. Not started until a handler exists.
@MainActor
final class VolumeKeyService: @unchecked Sendable {
    static let shared = VolumeKeyService()
    private init() {}

    enum Key: Sendable {
        case volumeUp, volumeDown, mute
    }

    /// Decides whether FreeAudio handles a key-down. Return true to consume the event.
    var handler: ((Key, _ isRepeat: Bool, _ modifiers: NSEvent.ModifierFlags) -> Bool)?

    var isRunning: Bool { eventTap != nil }

    /// Accessibility permission, which the event tap needs.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the macOS Accessibility prompt (once per launch at most).
    private var promptedForTrust = false
    func requestTrustIfNeeded() {
        guard !Self.isTrusted, !promptedForTrust else { return }
        promptedForTrust = true
        // The literal key: the kAXTrustedCheckOptionPrompt global isn't concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts the tap if it isn't running (e.g. after Accessibility was granted).
    func startIfNeeded() {
        guard eventTap == nil else { return }
        pollRetryCount = 0
        start()
    }

    // MARK: - Private State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Retained Unmanaged reference passed into the C callback. Released in stop().
    private var selfRetained: Unmanaged<VolumeKeyService>?
    /// Number of poll retries attempted.
    private var pollRetryCount = 0
    /// Max poll retries before giving up (2s × 15 = 30s).
    private static let maxPollRetries = 15

    // MARK: - NX Media Key Constants
    // Marked nonisolated(unsafe) so they can be read from the nonisolated callback method.
    // These are immutable compile-time constants so there is no data-race risk.

    /// CGEventType raw value for NSSystemDefined / NX_SYSDEFINED events (media keys).
    private nonisolated(unsafe) static let cgEventTypeSystemDefinedRaw: UInt32 = 14
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS — the subtype value for media/function keys.
    private nonisolated(unsafe) static let nxSubtypeAuxControlButtons: Int16 = 8
    /// NX_KEYTYPE_SOUND_UP / NX_KEYTYPE_SOUND_DOWN / NX_KEYTYPE_MUTE
    private nonisolated(unsafe) static let nxKeytypeSoundUp: Int = 0
    private nonisolated(unsafe) static let nxKeytypeSoundDown: Int = 1
    private nonisolated(unsafe) static let nxKeytypeMute: Int = 7

    // MARK: - Start / Stop

    /// Installs the event tap. Requires Accessibility permissions.
    /// Safe to call multiple times — a running tap will not be re-created.
    func start() {
        guard eventTap == nil else { return }

        // Try creating the tap directly — AXIsProcessTrusted can be unreliable
        // with ad-hoc signed builds (TCC entry invalidates after each rebuild).
        let retained = Unmanaged.passRetained(self)
        selfRetained = retained

        let systemDefinedMask = CGEventMask(1 << Self.cgEventTypeSystemDefinedRaw)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefinedMask,
            callback: volumeKeyEventCallback,
            userInfo: retained.toOpaque()
        )

        guard let tap else {
            retained.release()
            selfRetained = nil
            NSLog("[VolumeKeyService] Event tap creation failed — no accessibility permission")
            pollForAccessibility()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source

        NSLog("[VolumeKeyService] Event tap installed successfully")
    }

    /// Removes the event tap and releases the retained self reference.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil

        selfRetained?.release()
        selfRetained = nil
    }

    // MARK: - Accessibility Polling

    private var pollTimer: Timer?

    /// Polls every 2 seconds by attempting to create the tap. Stops after maxPollRetries.
    private func pollForAccessibility() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.pollRetryCount += 1
            if self.pollRetryCount > Self.maxPollRetries {
                NSLog("[VolumeKeyService] Gave up after %d retries — grant Accessibility permission and restart app", Self.maxPollRetries)
                timer.invalidate()
                self.pollTimer = nil
                return
            }
            timer.invalidate()
            self.pollTimer = nil
            self.start()
        }
    }

    // MARK: - Event Handling
    // Called from the C callback which runs on the main run loop thread.

    /// Returns the event to pass it through, nil to consume it.
    nonisolated func handleEventFromCallback(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if the system disabled it (e.g. after a timeout).
        if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue ||
           type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
            DispatchQueue.main.async {
                if let tap = self.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == Self.cgEventTypeSystemDefinedRaw,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.nxSubtypeAuxControlButtons
        else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 >> 16) & 0xFF
        let isKeyDown = ((data1 >> 8) & 0xFF) == 0x0A
        let isRepeat = (data1 & 0x1) != 0

        let key: Key
        switch keyCode {
        case Self.nxKeytypeSoundUp: key = .volumeUp
        case Self.nxKeytypeSoundDown: key = .volumeDown
        case Self.nxKeytypeMute: key = .mute
        default: return Unmanaged.passUnretained(event)
        }

        // Key-ups always pass through; only key-downs FreeAudio handles are consumed.
        guard isKeyDown else { return Unmanaged.passUnretained(event) }

        let modifiers = nsEvent.modifierFlags
        let consumed = MainActor.assumeIsolated { handler?(key, isRepeat, modifiers) ?? false }
        return consumed ? nil : Unmanaged.passUnretained(event)
    }
}

import AppKit
import CoreGraphics
import os

private let keyLog = Logger(subsystem: "com.freeaudio.app", category: "keys")

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
final class VolumeKeyService: ObservableObject, @unchecked Sendable {
    static let shared = VolumeKeyService()
    private init() {}

    enum Key: Sendable {
        case volumeUp, volumeDown, mute
    }

    /// Decides whether FreeAudio handles a key-down. Return true to consume the event.
    var handler: ((Key, _ isRepeat: Bool, _ modifiers: NSEvent.ModifierFlags) -> Bool)?

    /// True while the event tap runs. False before it is needed, and while macOS hasn't granted
    /// the permission it needs (Accessibility; Device Control and Data Access on macOS 27).
    @Published private(set) var isTapActive = false

    var isRunning: Bool { eventTap != nil }

    /// Accessibility permission, which the event tap needs.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Where the permission is in System Settings (the Accessibility list was renamed in
    /// macOS 27, FreeAudio's minimum).
    static var permissionSettingsPath: String {
        L("Gizlilik ve Güvenlik → Aygıt Denetimi ve Veri Erişimi",
          "Privacy & Security → Device Control and Data Access")
    }

    /// Starts the tap if it isn't running (e.g. after Accessibility was granted).
    func startIfNeeded() {
        start()
    }

    // MARK: - Private State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Retained Unmanaged reference passed into the C callback. Released in stop().
    private var selfRetained: Unmanaged<VolumeKeyService>?
    private var accessibilityObserver: NSObjectProtocol?
    private var retryTimer: Timer?

    // MARK: - NX Media Key Constants
    // `nonisolated` so the nonisolated callback method can read them (immutable Sendable values).

    /// CGEventType raw value for NSSystemDefined / NX_SYSDEFINED events (media keys).
    private nonisolated static let cgEventTypeSystemDefinedRaw: UInt32 = 14
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS: the subtype value for media/function keys.
    private nonisolated static let nxSubtypeAuxControlButtons: Int16 = 8
    /// NX_KEYTYPE_SOUND_UP / NX_KEYTYPE_SOUND_DOWN / NX_KEYTYPE_MUTE
    private nonisolated static let nxKeytypeSoundUp: Int = 0
    private nonisolated static let nxKeytypeSoundDown: Int = 1
    private nonisolated static let nxKeytypeMute: Int = 7

    // MARK: - Start / Stop

    /// Installs the event tap. Requires Accessibility permission; without it, retries when the
    /// permission changes (and every 10 s as a fallback) instead of giving up.
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
            if accessibilityObserver == nil {
                keyLog.notice("Event tap creation failed: no Accessibility / Device Control permission")
            }
            waitForAccessibility()
            requestPermissionsOncePerBuild()
            return
        }

        stopWaitingForAccessibility()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        isTapActive = true

        keyLog.notice("Event tap installed")
    }

    /// Removes the event tap and releases the retained self reference.
    func stop() {
        stopWaitingForAccessibility()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        isTapActive = false

        selfRetained?.release()
        selfRetained = nil
    }

    // MARK: - Accessibility

    /// The "Open" button next to the permission hint: asks macOS for the permission and opens
    /// the System Settings page. The tap starts as soon as it is granted.
    ///
    /// Records left by an earlier build with another signature (every ad-hoc build, i.e. all
    /// versions before 2.2) make macOS deny the tap without asking, and turning FreeAudio on in
    /// the list doesn't repair them. So when the tap still can't start, FreeAudio's own records
    /// are cleared first, and macOS asks again.
    func openPermissionSettings() {
        start()
        guard eventTap == nil else { return }
        requestPermissions()
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        start()
    }

    private static let permissionRequestBuildKey = "fa.volumeKeys.permissionRequestBuild"

    /// The first time a build can't start the tap, ask right away instead of waiting for the
    /// Settings button: without its own request macOS only denies the tap silently (an
    /// undecided or outdated record never shows a prompt by itself). Once per build, so a user
    /// who declined isn't asked at every launch.
    private func requestPermissionsOncePerBuild() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard UserDefaults.standard.string(forKey: Self.permissionRequestBuildKey) != build else { return }
        UserDefaults.standard.set(build, forKey: Self.permissionRequestBuildKey)
        requestPermissions()
    }

    /// Clears FreeAudio's own permission records and asks again. The active event tap rests on
    /// the Accessibility grant (Device Control and Data Access on macOS 27); macOS derives the
    /// PostEvent and ListenEvent checks from it ("service policy") and won't prompt for those
    /// directly. Records an earlier build with another signature left behind keep failing even
    /// after the user flips the switch, so they are removed, and the Accessibility request shows
    /// the system prompt with its "Open System Settings" button and a fresh entry in the list.
    private func requestPermissions() {
        for service in ["Accessibility", "PostEvent", "ListenEvent"] {
            PermissionService.resetOwnRecord(service)
        }
        keyLog.notice("Cleared FreeAudio's key permission records; asking for Accessibility")
        // The literal key: the kAXTrustedCheckOptionPrompt global isn't concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = CGRequestListenEventAccess()
    }

    private func waitForAccessibility() {
        if accessibilityObserver == nil {
            // Posted when any app's Accessibility permission changes. TCC updates its database
            // a moment later, so try again after a short delay.
            accessibilityObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    for delay in [0.5, 2.0] {
                        try? await Task.sleep(for: .seconds(delay))
                        // stop() ended the wait meanwhile: don't start a tap nobody wants.
                        guard VolumeKeyService.shared.accessibilityObserver != nil else { return }
                        VolumeKeyService.shared.start()
                        if VolumeKeyService.shared.isRunning { return }
                    }
                }
            }
        }
        if retryTimer == nil {
            let timer = Timer(timeInterval: 10, repeats: true) { _ in
                MainActor.assumeIsolated { VolumeKeyService.shared.start() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
    }

    private func stopWaitingForAccessibility() {
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
        retryTimer?.invalidate()
        retryTimer = nil
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

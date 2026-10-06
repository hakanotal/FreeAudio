import AppKit
import CoreGraphics

// MARK: - OSDUIHelper Protocol (Private API)

/// OSDImage values for the native macOS OSD.
@objc enum OSDImage: CLong {
    case brightness = 1
    case volume = 3
    case mute = 4
    case eject = 6
}

/// XPC protocol matching OSDUIHelper's interface.
/// This version (with filledChiclets/totalChiclets) shows the level bar.
@objc protocol OSDUIHelperProtocol {
    func showImage(
        _ img: OSDImage,
        onDisplayID displayID: CGDirectDisplayID,
        priority: CUnsignedInt,
        msecUntilFade: CUnsignedInt,
        filledChiclets: CUnsignedInt,
        totalChiclets: CUnsignedInt,
        locked: Bool
    )
}

// MARK: - VolumeHUDService

/// Shows the native macOS volume OSD via the private OSDUIHelper XPC service, the same
/// indicator macOS shows for its own volume keys. Used when FreeAudio handles the keys itself
/// (outputs without hardware volume). MonitorControl and BetterDisplay use the same service.
@MainActor
final class VolumeHUDService: @unchecked Sendable {
    static let shared = VolumeHUDService()
    private init() {}

    // MARK: - Public API

    /// Shows the volume OSD on the main display.
    /// - Parameters:
    ///   - volume: Slider position 0–1
    ///   - muted: Shows the mute image with an empty bar
    func show(volume: Double, muted: Bool) {
        let totalChiclets: CUnsignedInt = 16
        let filledChiclets = muted ? 0 : CUnsignedInt((min(max(volume, 0), 1) * Double(totalChiclets)).rounded())

        let conn = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: OSDUIHelperProtocol.self)
        // @Sendable: XPC calls these on its own queue, never the main thread.
        conn.interruptionHandler = { @Sendable in NSLog("[VolumeHUD] XPC connection interrupted") }
        conn.invalidationHandler = { @Sendable in NSLog("[VolumeHUD] XPC connection invalidated") }
        conn.resume()

        // @Sendable: XPC calls this on its own queue; an implicitly main-isolated closure would trap.
        let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable error in
            NSLog("[VolumeHUD] XPC error: %@", error.localizedDescription)
        }

        guard let helper = proxy as? OSDUIHelperProtocol else {
            NSLog("[VolumeHUD] Failed to get OSDUIHelper proxy")
            conn.invalidate()
            return
        }

        helper.showImage(
            muted || filledChiclets == 0 ? .mute : .volume,
            onDisplayID: CGMainDisplayID(),
            priority: 0x1f4,
            msecUntilFade: 1500,
            filledChiclets: filledChiclets,
            totalChiclets: totalChiclets,
            locked: false
        )

        // Invalidate after a short delay to allow the XPC message to be delivered
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            conn.invalidate()
        }
    }
}

import CoreAudio
import Foundation

/// Volume and mute of the default output device. Hardware devices are read and written through
/// `VirtualMainVolume` and `Mute`; devices without a volume control get software volume in
/// Phase 4 (until then their slider is disabled).
@MainActor
final class DeviceVolumeService: ObservableObject, @unchecked Sendable {
    static let shared = DeviceVolumeService()
    private init() {}

    enum Tier: Sendable {
        case hardware, software
    }

    /// Slider position 0–1. For hardware devices this is the driver's volume scalar, which is
    /// already tapered (no extra curve).
    @Published private(set) var volume: Double = 1
    @Published private(set) var isMuted = false
    @Published private(set) var canMute = false
    @Published private(set) var tier: Tier = .hardware
    @Published private(set) var deviceUID: String?

    private var device: AudioHardwareDevice?
    private var listeners: [PropertyListener] = []
    private var rereadTask: Task<Void, Never>?

    /// Follows `device` (the default output). Safe to call repeatedly with the same device.
    func bind(to audioDevice: AudioDevice?) {
        guard audioDevice?.uid != deviceUID || audioDevice?.objectID != device?.id else { return }
        listeners.forEach { $0.cancel() }
        listeners = []
        rereadTask?.cancel()
        deviceUID = audioDevice?.uid
        guard let audioDevice else {
            device = nil
            return
        }
        let hardwareDevice = AudioHardwareDevice(id: audioDevice.objectID)
        device = hardwareDevice
        tier = audioDevice.hasHardwareVolume ? .hardware : .software

        // Some drivers only notify per channel; listen to the first address that exists.
        for address in [CoreAudioAddress.virtualMainVolume, CoreAudioAddress.volumeScalarMain, CoreAudioAddress.volumeScalarLeft] {
            if let listener = PropertyListener(object: audioDevice.objectID, address: address, handler: { [weak self] in self?.read() }) {
                listeners.append(listener)
                break
            }
        }
        if let listener = PropertyListener(object: audioDevice.objectID, address: CoreAudioAddress.mute, handler: { [weak self] in self?.read() }) {
            listeners.append(listener)
        }
        read()
        // Bluetooth devices report 1.0 until their handshake finishes; read again shortly.
        if audioDevice.transport == .bluetooth {
            rereadTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.read()
            }
        }
    }

    private func read() {
        guard let device else { return }
        if tier == .hardware, let scalar = device.float32(CoreAudioAddress.virtualMainVolume) {
            // The left/right notifications arrive separately with the same value; skip repeats.
            let value = Double(scalar)
            if abs(value - volume) > 0.0001 { volume = value }
        }
        let mutable = device.isSettable(CoreAudioAddress.mute)
        if mutable != canMute { canMute = mutable }
        let muted = (device.uint32(CoreAudioAddress.mute) ?? 0) != 0
        if muted != isMuted { isMuted = muted }
    }

    func setVolume(_ value: Double) {
        guard tier == .hardware, let device else { return }
        let clamped = min(max(value, 0), 1)
        volume = clamped
        try? device.setFloat32(Float32(clamped), CoreAudioAddress.virtualMainVolume)
        // Moving the slider up unmutes, as the macOS volume control does.
        if isMuted, clamped > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard canMute, let device else { return }
        isMuted = muted
        try? device.setUInt32(muted ? 1 : 0, CoreAudioAddress.mute)
    }
}

import CoreAudio
import Foundation

/// Input level and mute of the default input device (microphone), through the input-scope
/// `VirtualMainVolume` and `Mute` properties. Many USB microphones have no settable level;
/// then the slider is disabled. Changing the level needs no permission (nothing is recorded).
@MainActor
final class InputVolumeService: ObservableObject, @unchecked Sendable {
    static let shared = InputVolumeService()
    private init() {}

    /// Input level 0–1 (the driver's volume scalar).
    @Published private(set) var volume: Double = 1
    @Published private(set) var isMuted = false
    @Published private(set) var canSetVolume = false
    @Published private(set) var canMute = false
    @Published private(set) var deviceUID: String?

    private var device: AudioHardwareDevice?
    private var listeners: [PropertyListener] = []

    /// Follows the default input. Safe to call repeatedly with the same device; `force`
    /// re-registers the listeners anyway.
    func bind(to audioDevice: AudioDevice?, force: Bool = false) {
        guard force || audioDevice?.uid != deviceUID || audioDevice?.objectID != device?.id else { return }
        listeners.forEach { $0.cancel() }
        listeners = []
        deviceUID = audioDevice?.uid
        guard let audioDevice else {
            device = nil
            return
        }
        device = AudioHardwareDevice(id: audioDevice.objectID)
        // Some drivers only notify per channel; listen to the first address that exists.
        for address in [CoreAudioAddress.inputVirtualMainVolume, CoreAudioAddress.inputVolumeScalarMain, CoreAudioAddress.inputVolumeScalarLeft] {
            if let listener = PropertyListener(object: audioDevice.objectID, address: address, handler: { [weak self] in self?.read() }) {
                listeners.append(listener)
                break
            }
        }
        if let listener = PropertyListener(object: audioDevice.objectID, address: CoreAudioAddress.inputMute, handler: { [weak self] in self?.read() }) {
            listeners.append(listener)
        }
        read()
    }

    /// coreaudiod restarted: its listeners are gone even when the device kept its object ID.
    func rebind() {
        bind(to: DeviceService.shared.defaultInput, force: true)
    }

    private func read() {
        guard let device else { return }
        let settable = device.isSettable(CoreAudioAddress.inputVirtualMainVolume)
        if settable != canSetVolume { canSetVolume = settable }
        if let scalar = device.float32(CoreAudioAddress.inputVirtualMainVolume) {
            let value = Double(scalar)
            if abs(value - volume) > 0.0001 { volume = value }
        }
        let mutable = device.isSettable(CoreAudioAddress.inputMute)
        if mutable != canMute { canMute = mutable }
        let muted = (device.uint32(CoreAudioAddress.inputMute) ?? 0) != 0
        if muted != isMuted { isMuted = muted }
    }

    func setVolume(_ value: Double) {
        guard canSetVolume, let device else { return }
        let clamped = min(max(value, 0), 1)
        do {
            try device.setFloat32(Float32(clamped), CoreAudioAddress.inputVirtualMainVolume)
            volume = clamped
        } catch {
            engineLog.error("Setting the input level failed: \(error.localizedDescription, privacy: .public)")
            read()
        }
    }

    /// Mutes the microphone. The UI shows what the device reports afterwards, never the request:
    /// a failed write must not show a live microphone as muted.
    func setMuted(_ muted: Bool) {
        guard canMute, let device else { return }
        do {
            try device.setUInt32(muted ? 1 : 0, CoreAudioAddress.inputMute)
        } catch {
            engineLog.error("Muting the input failed: \(error.localizedDescription, privacy: .public)")
        }
        read()
    }
}

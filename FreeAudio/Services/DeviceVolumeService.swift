import Combine
import CoreAudio
import Foundation

/// Volume and mute of the default output device. Hardware devices are read and written through
/// `VirtualMainVolume` and `Mute`. Devices without a working volume control (HDMI/DisplayPort
/// monitors, or a forced override) get software volume: the setting is stored per device UID and
/// `TapService` applies it with a rest tap.
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
    @Published private(set) var deviceName: String = ""

    private var device: AudioHardwareDevice?
    private var hasHardwareVolume = true
    private var cancellables: Set<AnyCancellable> = []
    private var listeners: [PropertyListener] = []
    private var rereadTask: Task<Void, Never>?

    /// Follows `device` (the default output). Safe to call repeatedly with the same device.
    func bind(to audioDevice: AudioDevice?) {
        if cancellables.isEmpty {
            // Software volume and the override live in settings.
            SettingsService.shared.$deviceSettings
                .sink { [weak self] _ in Task { @MainActor in self?.applyTier(); self?.read() } }
                .store(in: &cancellables)
        }
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
        deviceName = audioDevice.name
        hasHardwareVolume = audioDevice.hasHardwareVolume
        applyTier()

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

    /// Software when the device has no settable volume control or the user forced it.
    private func applyTier() {
        guard let deviceUID else { return }
        let forced = SettingsService.shared.deviceSetting(for: deviceUID).forceSoftware
        let newTier: Tier = hasHardwareVolume && !forced ? .hardware : .software
        if newTier != tier { tier = newTier }
    }

    private func read() {
        guard let device, let deviceUID else { return }
        if tier == .software {
            let setting = SettingsService.shared.deviceSetting(for: deviceUID)
            if abs(setting.softwareVolume - volume) > 0.0001 { volume = setting.softwareVolume }
            if setting.softwareMuted != isMuted { isMuted = setting.softwareMuted }
            if !canMute { canMute = true }
            return
        }
        if let scalar = device.float32(CoreAudioAddress.virtualMainVolume) {
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
        guard let device, let deviceUID else { return }
        let clamped = min(max(value, 0), 1)
        volume = clamped
        if tier == .software {
            SettingsService.shared.updateDeviceSetting(deviceUID, name: deviceName) { setting in
                setting.softwareVolume = clamped
                // Moving the slider up unmutes, as the macOS volume control does.
                if clamped > 0 { setting.softwareMuted = false }
            }
            if clamped > 0 { isMuted = false }
            return
        }
        try? device.setFloat32(Float32(clamped), CoreAudioAddress.virtualMainVolume)
        if isMuted, clamped > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard canMute, let device, let deviceUID else { return }
        isMuted = muted
        if tier == .software {
            SettingsService.shared.updateDeviceSetting(deviceUID, name: deviceName) { $0.softwareMuted = muted }
            return
        }
        try? device.setUInt32(muted ? 1 : 0, CoreAudioAddress.mute)
    }

    /// Volume-key step on the software tier: `step` is a slider fraction (±1/16, or ±1/64 with
    /// Option+Shift). Volume up unmutes; reaching 0 is left unmuted, like macOS.
    func step(by step: Double) {
        if isMuted, step > 0 { setMuted(false) }
        setVolume(volume + step)
    }

    /// Use software volume for a device that has a hardware control (when that control doesn't
    /// actually change the level).
    func setForceSoftware(_ forced: Bool, for device: AudioDevice) {
        SettingsService.shared.updateDeviceSetting(device.uid, name: device.name) { $0.forceSoftware = forced }
    }

    func isForcedSoftware(_ device: AudioDevice) -> Bool {
        SettingsService.shared.deviceSetting(for: device.uid).forceSoftware
    }
}

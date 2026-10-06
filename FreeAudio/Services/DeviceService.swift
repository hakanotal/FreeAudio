import CoreAudio
import Foundation

/// Output devices and the default output: listing, live updates and switching.
@MainActor
final class DeviceService: ObservableObject, @unchecked Sendable {
    static let shared = DeviceService()
    private init() {}

    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var defaultOutputUID: String?

    var defaultOutput: AudioDevice? {
        outputDevices.first { $0.uid == defaultOutputUID }
    }

    private var listeners: [PropertyListener] = []
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard listeners.isEmpty else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        // Device list changes arrive in bursts (Bluetooth sends 2-3 within ~20 ms, and reading
        // the list mid-burst fails), so coalesce them.
        for address in [CoreAudioAddress.devices, CoreAudioAddress.defaultOutputDevice] {
            if let listener = PropertyListener(object: system, address: address, handler: { [weak self] in
                self?.scheduleRefresh()
            }) {
                listeners.append(listener)
            }
        }
        refresh()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        let system = AudioHardwareSystem.shared
        let devices = ((try? system.devices) ?? []).compactMap(Self.makeOutputDevice)
        if devices != outputDevices { outputDevices = devices }
        let defaultUID = try? system.defaultOutputDevice?.uid
        if defaultUID != defaultOutputUID { defaultOutputUID = defaultUID }
    }

    private static func makeOutputDevice(_ device: AudioHardwareDevice) -> AudioDevice? {
        guard let uid = try? device.uid, !uid.hasPrefix(freeAudioAggregatePrefix),
              (try? device.isHidden) != true,
              (try? device.isAlive) != false,
              ((try? device.streams) ?? []).contains(where: { (try? $0.direction) == .output })
        else { return nil }
        return AudioDevice(
            objectID: device.id,
            uid: uid,
            name: (try? device.name) ?? uid,
            transport: AudioDevice.Transport((try? device.transportType) ?? 0),
            hasHardwareVolume: device.isSettable(CoreAudioAddress.virtualMainVolume)
        )
    }

    /// Makes `device` the default output. Alert sounds move with it when they were following the
    /// old default, as System Settings does.
    func setDefaultOutput(_ device: AudioDevice) {
        let system = AudioHardwareSystem.shared
        guard let target = try? system.device(forUID: device.uid) else { return }
        let previousUID = try? system.defaultOutputDevice?.uid
        let soundEffectsUID = try? system.defaultSoundEffectsDevice?.uid
        do {
            try system.setDefaultOutputDevice(target)
            if soundEffectsUID == previousUID {
                try? system.setDefaultSoundEffectsDevice(target)
            }
        } catch {
            NSLog("[DeviceService] Switching output to %@ failed: %@", device.name, error.localizedDescription)
        }
        refresh()
    }
}

import Combine
import CoreAudio
import Foundation

/// Output devices and the default output: listing, live updates and switching.
@MainActor
final class DeviceService: ObservableObject, @unchecked Sendable {
    static let shared = DeviceService()
    private init() {}

    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var defaultInputUID: String?

    var defaultInput: AudioDevice? {
        inputDevices.first { $0.uid == defaultInputUID }
    }

    var defaultOutput: AudioDevice? {
        outputDevices.first { $0.uid == defaultOutputUID }
    }

    /// A device's nominal sample rate changed (Bluetooth call mode, Audio MIDI Setup). An aggregate
    /// on that device goes silent until it is rebuilt.
    let sampleRateChanged = PassthroughSubject<String, Never>()
    /// coreaudiod restarted: every object ID and listener is gone.
    let serviceRestarted = PassthroughSubject<Void, Never>()

    private var listeners: [PropertyListener] = []
    private var refreshTask: Task<Void, Never>?
    private var rateListeners: [String: PropertyListener] = [:]
    private var rateListenerObjects: [String: AudioObjectID] = [:]
    private var sampleRates: [String: Double] = [:]
    private var rateTasks: [String: Task<Void, Never>] = [:]

    func start() {
        guard listeners.isEmpty else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let listener = PropertyListener(object: system, address: CoreAudioAddress.serviceRestarted, handler: { [weak self] in
            engineLog.notice("coreaudiod restarted")
            self?.serviceRestarted.send()
        }) {
            listeners.append(listener)
        }
        // Device list changes arrive in bursts (Bluetooth sends 2-3 within ~20 ms, and reading
        // the list mid-burst fails), so coalesce them.
        for address in [CoreAudioAddress.devices, CoreAudioAddress.defaultOutputDevice, CoreAudioAddress.defaultInputDevice] {
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
        var outputs: [AudioDevice] = []
        var inputs: [AudioDevice] = []
        // One pass: each device's UID, state and streams are read once for both lists.
        for device in (try? system.devices) ?? [] {
            guard let uid = try? device.uid, !uid.hasPrefix(freeAudioAggregatePrefix),
                  (try? device.isHidden) != true,
                  (try? device.isAlive) != false else { continue }
            let directions = ((try? device.streams) ?? []).compactMap { try? $0.direction }
            let hasOutput = directions.contains(.output)
            let hasInput = directions.contains(.input)
            guard hasOutput || hasInput else { continue }
            let name = (try? device.name) ?? uid
            let transport = AudioDevice.Transport((try? device.transportType) ?? 0)
            if hasOutput {
                outputs.append(AudioDevice(objectID: device.id, uid: uid, name: name, transport: transport,
                                           hasHardwareVolume: device.isSettable(CoreAudioAddress.virtualMainVolume)))
            }
            if hasInput {
                inputs.append(AudioDevice(objectID: device.id, uid: uid, name: name, transport: transport,
                                          hasHardwareVolume: device.isSettable(CoreAudioAddress.inputVirtualMainVolume)))
            }
        }
        if outputs != outputDevices { outputDevices = outputs }
        let defaultUID = try? system.defaultOutputDevice?.uid
        if defaultUID != defaultOutputUID { defaultOutputUID = defaultUID }
        if inputs != inputDevices { inputDevices = inputs }
        let defaultInput = try? system.defaultInputDevice?.uid
        if defaultInput != defaultInputUID { defaultInputUID = defaultInput }
        updateRateListeners()
    }

    /// Re-registers every listener (after coreaudiod restarted) and re-reads the devices.
    func restartListeners() {
        listeners.forEach { $0.cancel() }
        listeners = []
        rateListeners.values.forEach { $0.cancel() }
        rateListeners = [:]
        rateListenerObjects = [:]
        sampleRates = [:]
        start()
    }

    // MARK: - Sample rate

    private func updateRateListeners() {
        let current = Dictionary(outputDevices.map { ($0.uid, $0.objectID) }, uniquingKeysWith: { first, _ in first })
        for (uid, listener) in rateListeners where current[uid] != rateListenerObjects[uid] {
            listener.cancel()
            rateListeners.removeValue(forKey: uid)
            rateListenerObjects.removeValue(forKey: uid)
            sampleRates.removeValue(forKey: uid)
        }
        for (uid, objectID) in current where rateListeners[uid] == nil {
            sampleRates[uid] = AudioHardwareDevice(id: objectID).float64(CoreAudioAddress.nominalSampleRate)
            rateListeners[uid] = PropertyListener(object: objectID, address: CoreAudioAddress.nominalSampleRate) { [weak self] in
                self?.scheduleRateCheck(uid: uid, objectID: objectID)
            }
            rateListenerObjects[uid] = objectID
        }
    }

    /// Rate notifications come in bursts and a read can briefly return 0; check once things settle.
    private func scheduleRateCheck(uid: String, objectID: AudioObjectID) {
        rateTasks[uid]?.cancel()
        rateTasks[uid] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            guard let rate = AudioHardwareDevice(id: objectID).float64(CoreAudioAddress.nominalSampleRate), rate > 0 else { return }
            let previous = self.sampleRates[uid]
            self.sampleRates[uid] = rate
            if let previous, previous != rate {
                engineLog.notice("sample rate of \(uid, privacy: .private(mask: .hash)): \(previous) → \(rate)")
                self.sampleRateChanged.send(uid)
            }
        }
    }

    /// Makes `device` the default input (microphone).
    func setDefaultInput(_ device: AudioDevice) {
        let system = AudioHardwareSystem.shared
        guard let target = try? system.device(forUID: device.uid) else { return }
        do {
            try system.setDefaultInputDevice(target)
        } catch {
            // Device names can contain the user's name ("Hakan-iPhone Microphone"): keep them private.
            engineLog.error("Switching input to \(device.name, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
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
            engineLog.error("Switching output to \(device.name, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}

import AppKit
import Combine
import CoreAudio

/// Keeps one tap engine per controlled app. The main actor computes the desired engine set from
/// apps, settings and permission (`desiredSpecs`), `EngineDiff` turns the difference into actions,
/// and HAL work runs on `HALQueue`. Apps at default settings are never tapped.
@MainActor
final class TapService: ObservableObject, @unchecked Sendable {
    static let shared = TapService()
    private init() {}

    enum State: Sendable, Equatable {
        case ok
        /// Some app needs a tap but System Audio Recording is denied.
        case needsPermission
        /// A HAL call didn't return in time (often another app's tap on the same device).
        case stuck
    }

    @Published private(set) var state: State = .ok
    /// Keys of apps with a running engine, and of apps whose engine failed to start.
    @Published private(set) var activeKeys: Set<String> = []
    @Published private(set) var failedKeys: Set<String> = []
    /// Other tap-based audio apps that are running; taps from two processes on the same device
    /// interfere (`AudioDeviceStart` can block until the other tap goes away).
    @Published private(set) var conflictingApps: [String] = []

    private var engines: [String: TapEngine] = [:]
    private var specs: [String: EngineSpec] = [:]
    private var failureTimes: [String: Date] = [:]
    private var idleRestarts: [String: Date] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var watchdog: Timer?
    private var reconcileTask: Task<Void, Never>?
    private var lastDefaultUID: String?
    private var previousDefaultUID: String?
    private var defaultChangedAt: Date = .distantPast
    private var workspaceObservers: [NSObjectProtocol] = []
    /// When the default output's software volume returned to 100% (rest engine hysteresis).
    private var restUnitySince: Date?
    private var streamIndexCache: [String: UInt] = [:]

    /// After a default-output change, apps still reported on the old default follow the new one
    /// for this long (their Devices property can lag behind the move).
    private static let defaultFollowWindow: TimeInterval = 3

    /// Silence after which an engine's IO is restarted so the Mac can sleep (spike S3).
    private static let idleRestartAfter: TimeInterval = 3
    /// A failed engine isn't retried for this long.
    private static let failureBackoff: TimeInterval = 15
    /// Linear crossfade when an engine is rebuilt on the same device.
    private static let crossfadeSeconds = 0.05
    /// The rest engine outlives a return to 100% by this long, so dragging through 100% doesn't
    /// tear it down and rebuild it.
    private static let restHysteresis: TimeInterval = 2

    func start() {
        guard cancellables.isEmpty else { return }
        engineLog.notice("TapService started; System Audio Recording: \(String(describing: PermissionService.shared.status), privacy: .public)")
        AppAudioService.shared.$allApps
            .sink { [weak self] apps in
                guard let self else { return }
                // A controlled app without an engine plays unprocessed until we act: skip the debounce.
                let settings = SettingsService.shared
                if apps.contains(where: { !settings.appSetting(for: $0.id).isDefault && self.specs[$0.id] == nil }) {
                    Task { @MainActor in self.reconcile() }
                } else {
                    self.scheduleReconcile()
                }
            }
            .store(in: &cancellables)
        SettingsService.shared.$appSettings
            .sink { [weak self] _ in
                // Published before the value is stored: reconcile on the next turn.
                Task { @MainActor in self?.reconcile() }
            }
            .store(in: &cancellables)
        SettingsService.shared.$deviceSettings
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            }
            .store(in: &cancellables)
        DeviceService.shared.$outputDevices
            .sink { [weak self] _ in self?.scheduleReconcile() }
            .store(in: &cancellables)
        DeviceService.shared.$defaultOutputUID
            .sink { [weak self] uid in self?.defaultOutputChanged(to: uid) }
            .store(in: &cancellables)
        PermissionService.shared.$status
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            }
            .store(in: &cancellables)
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkEngines() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateConflicts() }
            })
        }
        updateConflicts()
    }

    /// The default output moved: re-read the apps right away (they follow the default) and
    /// re-check once the follow window has passed.
    private func defaultOutputChanged(to uid: String?) {
        guard uid != lastDefaultUID else { return }
        if lastDefaultUID != nil {
            previousDefaultUID = lastDefaultUID
            defaultChangedAt = Date()
        }
        lastDefaultUID = uid
        Task { @MainActor in
            AppAudioService.shared.refresh()
            self.reconcile()
            try? await Task.sleep(for: .seconds(Self.defaultFollowWindow + 0.2))
            AppAudioService.shared.refresh()
            self.reconcile()
        }
    }

    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    // MARK: - Desired state

    private func desiredSpecs() -> [String: EngineSpec] {
        let settings = SettingsService.shared
        let apps = AppAudioService.shared.allApps
        // Saved settings are never default, and their apps get (pre-armed) taps. A software
        // volume below 100% on the default output needs a rest tap.
        let defaultDevice = DeviceService.shared.defaultOutput
        let defaultDeviceSetting = defaultDevice.map { settings.deviceSetting(for: $0.uid) }
        let needsTaps = !settings.appSettings.isEmpty || defaultDeviceSetting.map { !$0.isUnity } == true
        let permission = PermissionService.shared
        if needsTaps, permission.status == .notDetermined { permission.requestIfNeeded() }
        guard permission.allowsTaps else {
            state = needsTaps ? .needsPermission : (state == .stuck ? .stuck : .ok)
            return [:]
        }
        if state == .needsPermission { state = .ok }

        let now = Date()
        let defaultUID = DeviceService.shared.defaultOutputUID ?? ""
        // Only real output devices: a tapped app's device list could include FreeAudio's own
        // private aggregate, and an engine must never target itself.
        let outputUIDs = Set(DeviceService.shared.outputDevices.map(\.uid))
        let defaultChangedRecently = now.timeIntervalSince(defaultChangedAt) < Self.defaultFollowWindow
        var desired: [String: EngineSpec] = [:]
        for app in apps {
            let setting = settings.appSetting(for: app.id)
            if let failed = failureTimes[app.id], now.timeIntervalSince(failed) < Self.failureBackoff { continue }
            if setting.isDefault {
                // Back at default: keep a running engine at unity while the app plays, so dragging
                // through 100% doesn't tear the tap down; drop it once the app is quiet.
                if var existing = specs[app.id], app.isPlaying {
                    existing.gain = 1
                    existing.processObjectIDs = app.processObjectIDs
                    desired[app.id] = existing
                }
                continue
            }
            let followed = EngineDiff.followedBundleIDs(appBundleID: app.bundleID, helperBundleIDs: app.helperBundleIDs)
            // Remember helper IDs so the pre-armed tap covers them next time the app starts.
            let helpers = followed.filter { $0 != app.bundleID }
            if !Set(helpers).isSubset(of: Set(setting.helpers ?? [])) {
                let merged = Array(Set(helpers).union(setting.helpers ?? [])).sorted()
                Task { @MainActor in settings.updateAppSetting(app.id, name: nil) { $0.helpers = merged } }
            }
            desired[app.id] = EngineSpec(
                key: app.id,
                deviceUID: EngineDiff.outputDevice(appDeviceUIDs: app.outputDeviceUIDs, outputUIDs: outputUIDs, defaultUID: defaultUID,
                                                   previousDefaultUID: previousDefaultUID, defaultChangedRecently: defaultChangedRecently),
                processObjectIDs: app.processObjectIDs,
                bundleIDs: EngineDiff.followedBundleIDs(appBundleID: app.bundleID, helperBundleIDs: app.helperBundleIDs + (setting.helpers ?? [])),
                gain: Self.gain(for: setting))
        }
        // Saved apps that aren't running get a pre-armed tap that follows their bundle ID, so
        // they're controlled from their first sound (spike S5: an empty tap costs nothing and
        // picks the app up when it starts). No process objects: Core Audio reuses object IDs,
        // and a tap must never pick up an unrelated process. Plain executables (`exec:`) have no
        // bundle ID to follow.
        let present = Set(apps.map(\.id))
        for (key, setting) in settings.appSettings where !present.contains(key) && !key.hasPrefix("exec:") {
            if let failed = failureTimes[key], now.timeIntervalSince(failed) < Self.failureBackoff { continue }
            desired[key] = EngineSpec(
                key: key,
                deviceUID: defaultUID,
                processObjectIDs: [],
                bundleIDs: EngineDiff.followedBundleIDs(appBundleID: key, helperBundleIDs: setting.helpers ?? []),
                gain: Self.gain(for: setting))
        }
        addSoftwareVolume(to: &desired, device: defaultDevice, setting: defaultDeviceSetting, now: now)
        return desired
    }

    /// Software volume on the default output (no hardware volume, or forced): a rest engine for
    /// everything that isn't a controlled app, and the device gain on the app engines there.
    private func addSoftwareVolume(to desired: inout [String: EngineSpec], device: AudioDevice?, setting: DeviceSetting?, now: Date) {
        guard let device, let setting, !device.hasHardwareVolume || setting.forceSoftware else {
            restUnitySince = nil
            return
        }
        let restKey = SoftwareVolumePlan.restKey(deviceUID: device.uid)
        if setting.isUnity {
            // Back at 100%: keep an existing rest engine briefly, then let audio play untouched.
            guard specs[restKey] != nil else { restUnitySince = nil; return }
            if restUnitySince == nil {
                restUnitySince = now
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.restHysteresis + 0.1))
                    self.reconcile()
                }
            }
            guard let since = restUnitySince, now.timeIntervalSince(since) < Self.restHysteresis else { return }
        } else {
            restUnitySince = nil
        }
        guard let stream = streamIndex(for: device) else { return }
        SoftwareVolumePlan.applyDeviceGain(&desired, deviceUID: device.uid, deviceGain: setting.gain)
        let ownObjects = (try? AudioHardwareSystem.shared.process(for: getpid())).map { [$0.id] } ?? []
        desired[restKey] = SoftwareVolumePlan.restSpec(
            deviceUID: device.uid, stream: stream, deviceGain: setting.gain,
            appSpecs: Array(desired.values), ownProcessObjectIDs: ownObjects,
            ownBundleID: Bundle.main.bundleIdentifier ?? "com.freeaudio.app")
    }

    /// Global index of the device's first output stream (the tap API wants the index in the
    /// device's full stream list).
    private func streamIndex(for device: AudioDevice) -> UInt? {
        if let cached = streamIndexCache[device.uid] { return cached }
        let streams = (try? AudioHardwareDevice(id: device.objectID).streams) ?? []
        guard let index = streams.firstIndex(where: { (try? $0.direction) == .output }) else { return nil }
        streamIndexCache[device.uid] = UInt(index)
        return UInt(index)
    }

    /// Muting is gain 0 on the regular engine: a gain change fades in 30 ms with no HAL work.
    /// (A bare `.muted` tap without an aggregate didn't silence a real app that the tap also
    /// followed by bundle ID; see LESSONS.)
    private static func gain(for setting: AppSetting) -> Float {
        setting.muted ? 0 : setting.gain
    }

    // MARK: - Applying

    func reconcile() {
        let actions = EngineDiff.actions(current: specs, desired: desiredSpecs())
        if !actions.isEmpty {
            engineLog.debug("reconcile: \(actions.count) action(s): \(String(describing: actions), privacy: .public)")
        }
        apply(actions)
    }

    private func apply(_ actions: [EngineAction]) {
        guard !actions.isEmpty else { return }
        // Devices whose rest engine is replaced in this batch: the new rest engine, app engines
        // created there and the outgoing engines all cross over at one host time (spike S3).
        let handoverDevices = Set(actions.compactMap { action -> String? in
            if case .replace(let spec) = action, case .rest = spec.kind { return spec.deviceUID }
            return nil
        })
        var incoming: [(engine: TapEngine, gain: Float)] = []
        var outgoing: [(engine: TapEngine, gain: Float)] = []

        for action in actions {
            switch action {
            case .create(let spec) where spec.kind == .app && handoverDevices.contains(spec.deviceUID):
                let engine = TapEngine(spec: spec)
                engine.setGain(0)
                engines[spec.key] = engine
                specs[spec.key] = spec
                incoming.append((engine, spec.gain))

            case .replace(let spec) where handoverDevices.contains(spec.deviceUID) && spec.kind != .app:
                if let old = engines[spec.key] { outgoing.append((old, specs[spec.key]?.gain ?? old.spec.gain)) }
                let engine = TapEngine(spec: spec)
                engine.setGain(0)
                engines[spec.key] = engine
                specs[spec.key] = spec
                incoming.append((engine, spec.gain))

            case .destroy(let key) where engines[key].map({ handoverDevices.contains($0.spec.deviceUID) }) == true:
                if let engine = engines.removeValue(forKey: key) { outgoing.append((engine, specs[key]?.gain ?? engine.spec.gain)) }
                specs.removeValue(forKey: key)

            case .setGain(let key, let gain):
                engines[key]?.setGain(gain)
                specs[key]?.gain = gain

            case .create(let spec):
                let engine = TapEngine(spec: spec)
                engines[spec.key] = engine
                specs[spec.key] = spec
                launch(engine, replacing: nil)

            case .replace(let spec):
                let old = engines[spec.key]
                let engine = TapEngine(spec: spec)
                engines[spec.key] = engine
                specs[spec.key] = spec
                launch(engine, replacing: old)

            case .updateTap(let key, let objects, let bundleIDs):
                guard let engine = engines[key], var spec = specs[key] else { continue }
                spec.processObjectIDs = objects
                spec.bundleIDs = bundleIDs
                specs[key] = spec
                Task { @MainActor in
                    let outcome = await HALQueue.shared.run { try engine.updateTap(processObjectIDs: objects, bundleIDs: bundleIDs) }
                    if case .failed(let message) = outcome {
                        engineLog.error("\(key, privacy: .public): in-place tap update failed (\(message, privacy: .public)), rebuilding")
                        guard self.engines[key] === engine, let current = self.specs[key] else { return }
                        self.apply([.replace(current)])
                    } else if outcome == .timedOut {
                        self.state = .stuck
                    }
                }

            case .destroy(let key):
                guard let engine = engines.removeValue(forKey: key) else { continue }
                specs.removeValue(forKey: key)
                // A rest engine is only removed at 100% (unity gain): stop it without a fade so the
                // untouched audio carries on seamlessly instead of dipping.
                retire(engine, fade: engine.spec.kind == .app)
            }
        }
        if !incoming.isEmpty || !outgoing.isEmpty { handover(incoming: incoming, outgoing: outgoing) }
        publishKeys()
    }

    /// Starts `incoming` silent, then crosses them over with `outgoing` at one host time, then
    /// retires `outgoing`.
    private func handover(incoming: [(engine: TapEngine, gain: Float)], outgoing: [(engine: TapEngine, gain: Float)]) {
        Task { @MainActor in
            var started: [(engine: TapEngine, gain: Float)] = []
            for item in incoming {
                let key = item.engine.spec.key
                let outcome = await HALQueue.shared.run { try item.engine.start() }
                switch outcome {
                case .done:
                    started.append(item)
                case .failed(let message):
                    engineLog.error("\(key, privacy: .public): engine failed to start: \(message, privacy: .public)")
                    failureTimes[key] = Date()
                    if engines[key] === item.engine {
                        engines.removeValue(forKey: key)
                        specs.removeValue(forKey: key)
                    }
                    retire(item.engine)
                case .timedOut:
                    state = .stuck
                }
            }
            // After the new engines' output gates have opened (40 ms fade on first sound).
            let start = HostClock.now + HostClock.ticks(0.1)
            for item in started {
                // Use the current gain: the user may have moved a slider meanwhile.
                let gain = specs[item.engine.spec.key]?.gain ?? item.gain
                item.engine.scheduleRamp(from: 0, to: gain, startHost: start, seconds: Self.crossfadeSeconds)
            }
            for item in outgoing {
                item.engine.scheduleRamp(from: item.gain, to: 0, startHost: start, seconds: Self.crossfadeSeconds)
            }
            try? await Task.sleep(for: .milliseconds(200))
            outgoing.forEach { retire($0.engine, fade: false) }
            publishKeys()
        }
    }

    /// Starts `engine`; once it runs, retires `old` (new before old, so the app is never heard
    /// unprocessed in between). On the same device both engines play the app for a moment, so
    /// the new one starts silent and they cross over with host-time ramps (spike S3).
    private func launch(_ engine: TapEngine, replacing old: TapEngine?) {
        let key = engine.spec.key
        let crossfade = old.map { $0.spec.deviceUID == engine.spec.deviceUID } ?? false
        if crossfade { engine.setGain(0) }
        Task { @MainActor in
            let outcome = await HALQueue.shared.run { try engine.start() }
            switch outcome {
            case .done:
                failureTimes.removeValue(forKey: key)
                if crossfade, let old {
                    // Start after the new engine's output gate has opened (40 ms fade on first sound).
                    let start = HostClock.now + HostClock.ticks(0.1)
                    let gain = specs[key]?.gain ?? engine.spec.gain
                    engine.scheduleRamp(from: 0, to: gain, startHost: start, seconds: Self.crossfadeSeconds)
                    // `gain` is also the old engine's current gain: gain changes go to both spec and engine.
                    old.scheduleRamp(from: gain, to: 0, startHost: start, seconds: Self.crossfadeSeconds)
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if let layout = engine.layoutDescription { engineLog.debug("\(key, privacy: .public): \(layout, privacy: .public)") }
            case .failed(let message):
                engineLog.error("\(key, privacy: .public): engine failed to start: \(message, privacy: .public)")
                failureTimes[key] = Date()
                if engines[key] === engine {
                    engines.removeValue(forKey: key)
                    specs.removeValue(forKey: key)
                }
                retire(engine)
            case .timedOut:
                engineLog.error("\(key, privacy: .public): engine start timed out")
                state = .stuck
            }
            if let old { retire(old) }
            publishKeys()
        }
    }

    /// Tears an engine down on the HAL queue, by default after fading it out.
    private func retire(_ engine: TapEngine, fade: Bool = true) {
        if fade { engine.setGain(0) }
        Task { @MainActor in
            let outcome = await HALQueue.shared.run {
                if fade { usleep(40_000) }  // let the 30 ms ramp reach silence
                engine.stop()
            }
            if outcome == .timedOut { state = .stuck }
        }
    }

    private func publishKeys() {
        let active = Set(engines.keys)
        if active != activeKeys { activeKeys = active }
        let now = Date()
        let failed = Set(failureTimes.filter { now.timeIntervalSince($0.value) < Self.failureBackoff }.keys)
        if failed != failedKeys { failedKeys = failed }
    }

    // MARK: - Watchdog

    /// Once a second: restart the IO of engines that have been silent, so the Mac can sleep.
    private func checkEngines() {
        let now = HostClock.now
        for (key, engine) in engines {
            let stats = engine.stats
            guard stats.callbacks > 0 else { continue }
            let runningRecently = HostClock.seconds(now &- stats.lastCallbackHost) < 0.5
            // Right after IO (re)starts an engine often hears nothing for a few hundred ms (an app
            // just starting, a stream moving to another device), and a pre-armed engine may have
            // been idle for hours: count silence from the IO start until the first sound.
            let silentFor = HostClock.seconds(now &- max(stats.lastSoundHost, stats.ioResumedHost))
            if runningRecently, silentFor > Self.idleRestartAfter {
                // Restart at most once per quiet spell (some apps keep a silent stream open, and
                // their IO would just start again).
                if let last = idleRestarts[key], Date().timeIntervalSince(last) < 60 { continue }
                idleRestarts[key] = Date()
                Task { _ = await HALQueue.shared.run { engine.restartIO() } }
                engineLog.debug("\(key, privacy: .public): idle for \(Int(silentFor)) s, IO restarted")
            } else if silentFor < 1 {
                idleRestarts.removeValue(forKey: key)
            }
        }
        if failedKeys.isEmpty == false { publishKeys() }
    }

    // MARK: - Recovery and shutdown

    /// A device's sample rate changed: its aggregates went silent, so rebuild their engines.
    func rebuildEngines(onDevice uid: String) {
        streamIndexCache.removeValue(forKey: uid)
        let affected = specs.values.filter { $0.deviceUID == uid }
        guard !affected.isEmpty else { return }
        engineLog.notice("rebuilding \(affected.count) engine(s) on \(uid, privacy: .public)")
        apply(affected.map { .replace($0) })
    }

    /// After wake, devices may have been reset: rebuild every engine once things settle, new
    /// before old so controlled apps are never heard unprocessed.
    func handleWake() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            engineLog.notice("rebuilding \(self.specs.count) engine(s) after wake")
            DeviceService.shared.refresh()
            AppAudioService.shared.refresh()
            apply(specs.values.map { .replace($0) })
            reconcile()
        }
    }

    /// coreaudiod restarted: every tap and aggregate is gone. Drop them and build again.
    func handleServiceRestart() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            restartAll()
        }
    }

    /// Known apps that also tap or reroute audio.
    private static let conflictingBundleIDs: Set<String> = [
        "com.rogueamoeba.soundsource", "com.rogueamoeba.audiohijack", "com.bitgapp.eqmac",
        "com.bearisdriving.BGM.App", "com.finetuneapp.FineTune",
    ]
    private static let conflictingNames: Set<String> = ["FineTune", "MonitorKeys", "Mimir", "SonicFlow", "SoundSource", "eqMac"]

    private func updateConflicts() {
        let names = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            if let id = app.bundleIdentifier, Self.conflictingBundleIDs.contains(id) { return app.localizedName ?? id }
            if let name = app.localizedName, Self.conflictingNames.contains(name) { return name }
            return nil
        }
        let sorted = Array(Set(names)).sorted()
        if sorted != conflictingApps { conflictingApps = sorted }
    }

    /// Tears every engine down and rebuilds from scratch ("Restart audio engine" in Settings).
    func restartAll() {
        let old = Array(engines.values)
        engines = [:]
        specs = [:]
        failureTimes = [:]
        idleRestarts = [:]
        old.forEach { retire($0) }
        state = .ok
        publishKeys()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            reconcile()
        }
    }

    /// Synchronous teardown on quit, capped at 2 s. Private taps also vanish with the process.
    func shutdown() {
        let all = Array(engines.values)
        engines = [:]
        specs = [:]
        guard !all.isEmpty else { return }
        HALQueue.shared.runAndWait(timeout: 2) {
            for engine in all { engine.stop() }
        }
    }

    /// Diagnostics lines for `--dump-audio`.
    func diagnostics() -> [String] {
        specs.keys.sorted().map { key in
            let spec = specs[key]!
            let engine = engines[key]
            return "  \(key): \(spec.kind) device=\(spec.deviceUID) gain=\(spec.gain) processes=\(spec.processObjectIDs) follows=\(spec.bundleIDs) callbacks=\(engine?.stats.callbacks ?? 0)"
        }
    }
}

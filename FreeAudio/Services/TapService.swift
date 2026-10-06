import Combine
import CoreAudio
import Foundation

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

    private var engines: [String: TapEngine] = [:]
    private var specs: [String: EngineSpec] = [:]
    private var failureTimes: [String: Date] = [:]
    private var idleRestarts: [String: Date] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var watchdog: Timer?
    private var reconcileTask: Task<Void, Never>?

    /// Silence after which an engine's IO is restarted so the Mac can sleep (spike S3).
    private static let idleRestartAfter: TimeInterval = 3
    /// A failed engine isn't retried for this long.
    private static let failureBackoff: TimeInterval = 15

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
        DeviceService.shared.$defaultOutputUID
            .sink { [weak self] _ in self?.scheduleReconcile() }
            .store(in: &cancellables)
        PermissionService.shared.$status
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            }
            .store(in: &cancellables)
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkEngines() }
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
        // Saved settings are never default, and their apps get (pre-armed) taps.
        let needsTaps = !settings.appSettings.isEmpty
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
                deviceUID: app.outputDeviceUIDs.first(where: outputUIDs.contains) ?? defaultUID,
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
        return desired
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
            engineLog.notice("reconcile: \(actions.count) action(s): \(String(describing: actions), privacy: .public)")
        }
        apply(actions)
    }

    private func apply(_ actions: [EngineAction]) {
        guard !actions.isEmpty else { return }
        for action in actions {
            switch action {
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

            case .updateProcesses(let key, let objects):
                guard let engine = engines[key], var spec = specs[key] else { continue }
                spec.processObjectIDs = objects
                specs[key] = spec
                Task { @MainActor in
                    let outcome = await HALQueue.shared.run { try engine.updateProcesses(objects) }
                    if case .failed(let message) = outcome {
                        engineLog.error("\(key, privacy: .public): in-place process update failed (\(message, privacy: .public)), rebuilding")
                        guard self.engines[key] === engine, let current = self.specs[key] else { return }
                        self.apply([.replace(current)])
                    } else if outcome == .timedOut {
                        self.state = .stuck
                    }
                }

            case .destroy(let key):
                guard let engine = engines.removeValue(forKey: key) else { continue }
                specs.removeValue(forKey: key)
                retire(engine)
            }
        }
        publishKeys()
    }

    /// Starts `engine`; once it runs, retires `old` (new before old, so the app is never heard
    /// unprocessed in between).
    private func launch(_ engine: TapEngine, replacing old: TapEngine?) {
        let key = engine.spec.key
        Task { @MainActor in
            let outcome = await HALQueue.shared.run { try engine.start() }
            switch outcome {
            case .done:
                failureTimes.removeValue(forKey: key)
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

    /// Fades an engine out and tears it down on the HAL queue.
    private func retire(_ engine: TapEngine) {
        engine.setGain(0)
        Task { @MainActor in
            let outcome = await HALQueue.shared.run {
                usleep(40_000)  // let the 30 ms ramp reach silence
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
            let silentFor = stats.lastSoundHost == 0 ? Double.infinity : HostClock.seconds(now &- stats.lastSoundHost)
            if runningRecently, silentFor > Self.idleRestartAfter {
                // Restart at most once per quiet spell (some apps keep a silent stream open, and
                // their IO would just start again).
                if let last = idleRestarts[key], Date().timeIntervalSince(last) < 60 { continue }
                idleRestarts[key] = Date()
                Task { _ = await HALQueue.shared.run { engine.restartIO() } }
                engineLog.debug("\(key, privacy: .public): idle, IO restarted")
            } else if silentFor < 1 {
                idleRestarts.removeValue(forKey: key)
            }
        }
        if failedKeys.isEmpty == false { publishKeys() }
    }

    // MARK: - Recovery and shutdown

    /// Tears every engine down and rebuilds from scratch ("Restart audio engine" in Settings).
    func restartAll() {
        let old = Array(engines.values)
        engines = [:]
        specs = [:]
        failureTimes = [:]
        idleRestarts = [:]
        old.forEach(retire)
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
            return "  \(key): device=\(spec.deviceUID) gain=\(spec.gain) processes=\(spec.processObjectIDs) follows=\(spec.bundleIDs) callbacks=\(engine?.stats.callbacks ?? 0)"
        }
    }
}

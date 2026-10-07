import AppKit
import Combine
import CoreAudio

/// Keeps one tap engine per controlled app. The main actor computes the desired engine set from
/// apps, settings and permission (`EnginePlan`), `EngineDiff` turns the difference into actions,
/// and HAL work runs on `HALQueue`. Apps at default settings are never tapped.
@MainActor
final class TapService: ObservableObject, @unchecked Sendable {
    static let shared = TapService()
    private init() {}

    enum State: Sendable, Equatable {
        case ok
        /// Some app needs a tap but System Audio Recording is denied.
        case needsPermission
        /// A HAL call has been running for seconds (often another app's tap on the same device).
        case stuck
    }

    @Published private(set) var state: State = .ok
    /// Keys of apps with a running engine, and of apps whose engine failed to start.
    @Published private(set) var activeKeys: Set<String> = []
    @Published private(set) var failedKeys: Set<String> = []
    /// Other tap-based audio apps that are running; taps from two processes on the same device
    /// interfere (`AudioDeviceStart` can block until the other tap goes away).
    @Published private(set) var conflictingApps: [String] = []

    /// The current engine (and its spec) per key.
    private var engines: [String: TapEngine] = [:]
    private var specs: [String: EngineSpec] = [:]
    /// Every engine not yet stopped, current or not (outgoing, fading, failed): `shutdown` and
    /// `restartAll` reach all of them.
    private var live: [ObjectIdentifier: TapEngine] = [:]
    private var retiring: Set<ObjectIdentifier> = []
    /// Engines starting silent for a crossfade, until it is over. Gain changes for them only go
    /// to their spec; the ramp, and the end of the crossfade, pick that up.
    private var crossfading: Set<ObjectIdentifier> = []
    /// The engine that keeps playing a key's audio while its replacement starts: it follows gain
    /// changes until the crossfade is scheduled.
    private var forwardTo: [String: TapEngine] = [:]

    /// Launches and handovers whose engines are still starting. Engine changes wait until they
    /// are done (gain changes don't), so a batch never sees its engines replaced halfway.
    private var inFlight = 0
    private var reconcileDeferred = false
    /// Bumped by `restartAll`, so batches it abandoned don't count down `inFlight`.
    private var generation = 0
    private var pendingRebuild: Set<String> = []
    private var reconcileQueued = false
    private var reconcileTask: Task<Void, Never>?

    private var failureTimes: [String: Date] = [:]
    /// Devices whose rest engine failed to start, by device UID.
    private var restFailures: [String: Date] = [:]
    private var idleRestarts: [String: Date] = [:]
    private var permissionMissing = false
    /// HAL calls awaited right now, and whether the running one has taken too long.
    private var pendingHAL = 0
    private var halStuck = false

    private var cancellables: Set<AnyCancellable> = []
    private var watchdog: Timer?
    private var watchdogTicks = 0
    private var lastDefaultUID: String?
    private var previousDefaultUID: String?
    private var defaultChangedAt: Date = .distantPast
    private var workspaceObservers: [NSObjectProtocol] = []
    /// When the default output's software volume returned to 100% (rest engine hysteresis).
    private var restUnitySince: Date?
    private var streamIndexCache: [String: UInt] = [:]
    private var ownProcessObjectID: AudioObjectID?

    /// After a default-output change, apps still reported on the old default follow the new one
    /// for this long (their Devices property can lag behind the move).
    private static let defaultFollowWindow: TimeInterval = 3
    /// Silence after which an engine's IO is restarted so the Mac can sleep (spike S3).
    private static let idleRestartAfter: TimeInterval = 3
    /// A failed engine isn't retried for this long; a failed rest engine for `restBackoff`.
    private static let failureBackoff: TimeInterval = 15
    private static let restBackoff: TimeInterval = 5
    /// Linear crossfade when an engine is rebuilt on the same device, starting this long after
    /// the new engine runs (its output gate opens with a 40 ms fade on first sound).
    private static let crossfadeSeconds = 0.05
    private static let crossfadeLead = 0.1
    /// An engine fades out through its 30 ms per-sample ramp before it is stopped: five time
    /// constants (-43 dB). Host-time ramps would depend on the output latency, which runs to
    /// hundreds of ms on Bluetooth.
    private static let fadeStopDelay: Duration = .milliseconds(150)
    /// The rest engine outlives a return to 100% by this long, so dragging through 100% doesn't
    /// tear it down and rebuild it.
    private static let restHysteresis: TimeInterval = 2
    /// A HAL call running longer than this shows the "stuck" notice.
    private static let halStuckAfter: Double = 3

    func start() {
        guard cancellables.isEmpty else { return }
        engineLog.notice("TapService started; System Audio Recording: \(String(describing: PermissionService.shared.status), privacy: .public)")
        AppAudioService.shared.$allApps
            .sink { [weak self] apps in
                guard let self else { return }
                // A controlled app without an engine plays unprocessed until we act: skip the debounce.
                let settings = SettingsService.shared
                if apps.contains(where: { !settings.appSetting(for: $0.id).isDefault && self.specs[$0.id] == nil }) {
                    self.requestReconcile()
                } else {
                    self.scheduleReconcile()
                }
            }
            .store(in: &cancellables)
        // These publish before the value is stored: `requestReconcile` runs on the next turn.
        SettingsService.shared.$appSettings
            .sink { [weak self] _ in self?.requestReconcile() }
            .store(in: &cancellables)
        SettingsService.shared.$deviceSettings
            .sink { [weak self] _ in self?.requestReconcile() }
            .store(in: &cancellables)
        PermissionService.shared.$status
            .sink { [weak self] _ in self?.requestReconcile() }
            .store(in: &cancellables)
        DeviceService.shared.$outputDevices
            .sink { [weak self] devices in
                guard let self else { return }
                let listed = Set(devices.map(\.uid))
                self.streamIndexCache = self.streamIndexCache.filter { listed.contains($0.key) }
                self.scheduleReconcile()
            }
            .store(in: &cancellables)
        DeviceService.shared.$defaultOutputUID
            .sink { [weak self] uid in self?.defaultOutputChanged(to: uid) }
            .store(in: &cancellables)
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

    /// One reconcile on the next main-actor turn, however many changes ask for it meanwhile.
    private func requestReconcile() {
        guard !reconcileQueued else { return }
        reconcileQueued = true
        Task { @MainActor [weak self] in self?.reconcile() }
    }

    /// Debounced, for bursts (app list, device list).
    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    /// Rebuilds the engines of `keys` with the same specs (dead aggregates after a sample-rate
    /// change, wake, a failed in-place update or IO restart).
    private func requestRebuild<Keys: Sequence>(_ keys: Keys) where Keys.Element == String {
        pendingRebuild.formUnion(keys)
        requestReconcile()
    }

    // MARK: - Desired state

    private func desiredPlan() -> EnginePlan.Result {
        let settings = SettingsService.shared
        let devices = DeviceService.shared
        let defaultDevice = devices.defaultOutput
        let defaultSetting = defaultDevice.map { settings.deviceSetting(for: $0.uid) } ?? DeviceSetting()
        let defaultIsSoftware = defaultDevice.map { defaultSetting.usesSoftwareVolume(hasHardwareVolume: $0.hasHardwareVolume) } ?? false
        // Saved settings are never default, and their apps get (pre-armed) taps. A software
        // volume below 100% on the default output needs a rest tap.
        let needsTaps = !settings.appSettings.isEmpty || (defaultIsSoftware && !defaultSetting.isUnity)
        let permission = PermissionService.shared
        if needsTaps { permission.requestIfNeeded() }
        let missing = needsTaps && !permission.allowsTaps
        if missing != permissionMissing {
            permissionMissing = missing
            refreshState()
        }
        guard permission.allowsTaps else { return EnginePlan.Result() }

        let now = Date()
        var input = EnginePlan.Input()
        input.apps = AppAudioService.shared.allApps
        input.appSettings = settings.appSettings
        input.deviceSettings = settings.deviceSettings
        input.outputUIDs = Set(devices.outputDevices.map(\.uid))
        input.softwareOutputUIDs = Set(devices.outputDevices
            .filter { settings.deviceSetting(for: $0.uid).usesSoftwareVolume(hasHardwareVolume: $0.hasHardwareVolume) }
            .map(\.uid))
        input.defaultUID = devices.defaultOutputUID
        input.previousDefaultUID = previousDefaultUID
        input.defaultChangedRecently = now.timeIntervalSince(defaultChangedAt) < Self.defaultFollowWindow
        input.current = specs
        input.backedOff = Set(failureTimes.filter { now.timeIntervalSince($0.value) < Self.failureBackoff }.keys)
        input.restBackedOff = Set(restFailures.filter { now.timeIntervalSince($0.value) < Self.restBackoff }.keys)
        if let defaultDevice, defaultIsSoftware {
            input.restStream = streamIndex(for: defaultDevice)
            input.ownProcessObjectIDs = ownProcessObjectIDs()
            input.ownBundleID = Bundle.main.bundleIdentifier ?? input.ownBundleID
        }
        // Back at 100%: keep an existing rest engine briefly, then let audio play untouched.
        if EnginePlan.restIsAtUnity(input) {
            if restUnitySince == nil {
                restUnitySince = now
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.restHysteresis + 0.1))
                    self?.requestReconcile()
                }
            }
            input.holdRestAtUnity = now.timeIntervalSince(restUnitySince ?? now) < Self.restHysteresis
        } else {
            restUnitySince = nil
        }
        return EnginePlan.desired(input)
    }

    /// Global index of the device's first output stream (the tap API wants the index in the
    /// device's full stream list).
    private func streamIndex(for device: AudioDevice) -> UInt? {
        if let cached = streamIndexCache[device.uid] { return cached }
        let streams = (try? AudioHardwareDevice(id: device.objectID).streams) ?? []
        guard let index = streams.firstIndex(where: { (try? $0.direction) == .output }) else {
            engineLog.error("No output stream for the rest tap on \(device.uid, privacy: .private(mask: .hash))")
            return nil
        }
        streamIndexCache[device.uid] = UInt(index)
        return UInt(index)
    }

    /// FreeAudio's own process object, excluded from rest taps. Stable for the process lifetime
    /// (until coreaudiod restarts); a failed lookup is retried next time.
    private func ownProcessObjectIDs() -> [UInt32] {
        if let id = ownProcessObjectID { return [id] }
        guard let process = try? AudioHardwareSystem.shared.process(for: getpid()) else { return [] }
        ownProcessObjectID = process.id
        return [process.id]
    }

    // MARK: - Applying

    func reconcile() {
        reconcileQueued = false
        if inFlight == 0, !pendingRebuild.isEmpty {
            let keys = pendingRebuild
            pendingRebuild = []
            apply(keys.sorted().compactMap { specs[$0] }.map { .replace($0) }, rebuilding: true)
        }
        let plan = desiredPlan()
        // Remember helper IDs so the pre-armed tap covers them next time the app starts.
        for (key, helpers) in plan.helpersToSave {
            SettingsService.shared.updateAppSetting(key, name: nil) { $0.helpers = helpers }
        }
        let actions = EngineDiff.actions(current: specs, desired: plan.specs)
        if !actions.isEmpty {
            engineLog.debug("reconcile: \(actions.count) action(s): \(String(describing: actions), privacy: .private)")
        }
        if inFlight > 0 {
            // Gains now; engines change once the running batch is done.
            apply(actions.filter(\.isGainOnly))
            if actions.contains(where: { !$0.isGainOnly }) || !pendingRebuild.isEmpty { reconcileDeferred = true }
        } else {
            apply(Self.prioritized(actions))
        }
        updateWatchdog()
    }

    /// Removals first, then gain and in-place changes, then engines for running apps, then the
    /// pre-armed ones (a device switch or wake rebuilds all of them; audible apps go first).
    private static func prioritized(_ actions: [EngineAction]) -> [EngineAction] {
        func rank(_ action: EngineAction) -> Int {
            switch action {
            case .destroy: return 0
            case .setGain, .updateTap: return 1
            case .create(let spec), .replace(let spec): return spec.kind == .app && spec.processObjectIDs.isEmpty ? 3 : 2
            }
        }
        return actions.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private struct Handoff {
        let engine: TapEngine
        let spec: EngineSpec
    }

    private func apply(_ actions: [EngineAction], rebuilding: Bool = false) {
        guard !actions.isEmpty else { return }
        // Devices whose rest engine is replaced because its exclusions changed: the new rest
        // engine, app engines created there and the outgoing engines all cross over at one host
        // time (spike S3). A rebuild keeps the exclusions and replaces engine by engine.
        let handoverDevices: Set<String> = rebuilding ? [] : Set(actions.compactMap { action -> String? in
            if case .replace(let spec) = action, case .rest = spec.kind { return spec.deviceUID }
            return nil
        })
        var incoming: [TapEngine] = []
        var outgoing: [Handoff] = []

        for action in actions {
            switch action {
            case .create(let spec) where spec.kind == .app && handoverDevices.contains(spec.deviceUID):
                incoming.append(install(spec, silent: true))

            case .replace(let spec) where spec.kind != .app && handoverDevices.contains(spec.deviceUID):
                if let old = engines[spec.key], let oldSpec = specs[spec.key] {
                    outgoing.append(Handoff(engine: old, spec: oldSpec))
                    forwardTo[spec.key] = old
                }
                incoming.append(install(spec, silent: true))

            case .destroy(let key) where engines[key].map({ handoverDevices.contains($0.spec.deviceUID) }) == true:
                if let engine = engines.removeValue(forKey: key), let spec = specs.removeValue(forKey: key) {
                    outgoing.append(Handoff(engine: engine, spec: spec))
                }

            case .setGain(let key, let gain):
                specs[key]?.gain = gain
                guard let engine = engines[key] else { continue }
                if crossfading.contains(ObjectIdentifier(engine)) {
                    // Its ramp picks up the spec gain. Until the ramp is scheduled the engine it
                    // replaces plays alone, so that one follows (mute must work during a slow start).
                    forwardTo[key]?.setGain(gain)
                } else {
                    engine.setGain(gain)
                }

            case .create(let spec):
                launch(install(spec, silent: false), replacing: nil)

            case .replace(let spec):
                let old = engines[spec.key]
                // On the same device both engines play the app for a moment: start silent and cross over.
                let sameDevice = old?.spec.deviceUID == spec.deviceUID
                launch(install(spec, silent: sameDevice), replacing: old)

            case .updateTap(let key, let objects, let bundleIDs):
                guard let engine = engines[key], var spec = specs[key] else { continue }
                spec.processObjectIDs = objects
                spec.bundleIDs = bundleIDs
                specs[key] = spec
                Task { @MainActor in
                    let outcome = await self.hal { try engine.updateTap(processObjectIDs: objects, bundleIDs: bundleIDs) }
                    if case .failed(let message) = outcome, self.engines[key] === engine {
                        engineLog.error("\(key, privacy: .public): in-place tap update failed (\(message, privacy: .public)), rebuilding")
                        self.requestRebuild([key])
                    }
                }

            case .destroy(let key):
                specs.removeValue(forKey: key)
                guard let engine = engines.removeValue(forKey: key) else { continue }
                // A rest engine is removed at 100% (or when its device stops being the default):
                // stop it without a fade, so the untouched audio carries on instead of dipping.
                retire(engine, fade: engine.spec.kind == .app)
            }
        }
        if !incoming.isEmpty {
            handover(incoming: incoming, outgoing: outgoing)
        } else {
            outgoing.forEach { retire($0.engine) }
        }
        publishKeys()
    }

    private func install(_ spec: EngineSpec, silent: Bool) -> TapEngine {
        let engine = TapEngine(spec: spec)
        let id = ObjectIdentifier(engine)
        if silent {
            engine.setGain(0)
            crossfading.insert(id)
        }
        engines[spec.key] = engine
        specs[spec.key] = spec
        live[id] = engine
        return engine
    }

    private func isLive(_ engine: TapEngine) -> Bool {
        let id = ObjectIdentifier(engine)
        return live[id] != nil && !retiring.contains(id)
    }

    private func beginFlight() -> Int {
        inFlight += 1
        return generation
    }

    private func endFlight(_ flightGeneration: Int) {
        guard flightGeneration == generation else { return }
        inFlight = max(inFlight - 1, 0)
        if inFlight == 0, reconcileDeferred {
            reconcileDeferred = false
            requestReconcile()
        }
        updateWatchdog()
    }

    /// Starts `engine`; once it runs, retires `old` (new before old, so the app is never heard
    /// unprocessed in between). On the same device the new engine starts silent and they cross
    /// over with host-time ramps (spike S3).
    private func launch(_ engine: TapEngine, replacing old: TapEngine?) {
        let key = engine.spec.key
        let crossfade = old != nil && crossfading.contains(ObjectIdentifier(engine))
        if crossfade, let old { forwardTo[key] = old }
        let flight = beginFlight()
        Task { @MainActor in
            defer { self.endFlight(flight) }
            let outcome = await self.hal { try engine.start() }
            if let old, self.forwardTo[key] === old { self.forwardTo.removeValue(forKey: key) }
            guard self.isLive(engine) else { return }  // restartAll took over
            switch outcome {
            case .done:
                if self.engines[key] === engine { self.failureTimes.removeValue(forKey: key) }
                if crossfade, let old {
                    let start = HostClock.now + HostClock.ticks(Self.crossfadeLead)
                    engine.scheduleRamp(from: 0, to: self.specs[key]?.gain ?? engine.spec.gain, startHost: start, seconds: Self.crossfadeSeconds)
                    old.scheduleRamp(from: old.currentGain, to: 0, startHost: start, seconds: Self.crossfadeSeconds)
                    try? await Task.sleep(for: .milliseconds(200))
                    self.finishCrossfade(engine)
                    self.retire(old, fade: false)
                } else if let old {
                    self.retire(old)
                }
                if let layout = engine.layoutDescription { engineLog.debug("\(key, privacy: .public): \(layout, privacy: .public)") }
            case .failed(let message):
                engineLog.error("\(key, privacy: .public): engine failed to start: \(message, privacy: .public)")
                if let old, self.engines[key] === engine, old.spec.deviceUID == engine.spec.deviceUID, self.isLive(old),
                   HostClock.seconds(HostClock.now &- old.stats.lastCallbackHost) < 0.5 {
                    // A rebuild failed but the old engine is still playing (wake rebuilds healthy
                    // engines too): keep it.
                    var spec = old.spec
                    spec.gain = self.specs[key]?.gain ?? spec.gain
                    self.engines[key] = old
                    self.specs[key] = spec
                    old.setGain(spec.gain)
                    self.retire(engine, fade: false)
                    break
                }
                if case .rest = engine.spec.kind {
                    if self.engines[key] === engine {
                        self.restFailures[engine.spec.deviceUID] = Date()
                        self.scheduleRetry(after: Self.restBackoff)
                    }
                } else {
                    self.recordFailure(key, engine: engine)
                }
                if self.engines[key] === engine {
                    self.engines.removeValue(forKey: key)
                    self.specs.removeValue(forKey: key)
                }
                self.retire(engine, fade: false)
                // The old engine plays to a device the app left, or went silent with a rate
                // change: the app plays untouched until the retry.
                if let old { self.retire(old) }
                // A rest engine may still exclude this app: rebuild the plan once this batch is done.
                self.reconcileDeferred = true
            }
            self.publishKeys()
        }
    }

    /// Starts `incoming` silent, then crosses them over with `outgoing` at one host time, then
    /// retires `outgoing`. If the new rest engine doesn't start, the handover is called off:
    /// the old rest engine must never go before its replacement runs (ownership rule).
    private func handover(incoming: [TapEngine], outgoing: [Handoff]) {
        let flight = beginFlight()
        Task { @MainActor in
            defer { self.endFlight(flight) }
            var failedApps: [TapEngine] = []
            var failedRest: TapEngine?
            for engine in incoming {
                if case .failed(let message) = await self.hal({ try engine.start() }) {
                    engineLog.error("\(engine.spec.key, privacy: .public): engine failed to start: \(message, privacy: .public)")
                    if engine.spec.kind == .app { failedApps.append(engine) } else { failedRest = engine }
                }
            }
            for handoff in outgoing where self.forwardTo[handoff.spec.key] === handoff.engine {
                self.forwardTo.removeValue(forKey: handoff.spec.key)
            }
            guard incoming.allSatisfy(self.isLive) else { return }  // restartAll took over

            if let failedRest {
                for engine in incoming {
                    if self.engines[engine.spec.key] === engine {
                        self.engines.removeValue(forKey: engine.spec.key)
                        self.specs.removeValue(forKey: engine.spec.key)
                    }
                    self.retire(engine, fade: false)
                }
                for handoff in outgoing where self.engines[handoff.spec.key] == nil {
                    self.engines[handoff.spec.key] = handoff.engine
                    self.specs[handoff.spec.key] = handoff.spec
                }
                self.restFailures[failedRest.spec.deviceUID] = Date()
                self.scheduleRetry(after: Self.restBackoff)
                self.publishKeys()
                return
            }

            for engine in failedApps {
                self.recordFailure(engine.spec.key, engine: engine)
                if self.engines[engine.spec.key] === engine {
                    self.engines.removeValue(forKey: engine.spec.key)
                    self.specs.removeValue(forKey: engine.spec.key)
                }
                self.retire(engine, fade: false)
            }
            // The new rest engine excludes the apps that failed: rebuild it without them.
            if !failedApps.isEmpty { self.reconcileDeferred = true }

            let started = incoming.filter { engine in !failedApps.contains { $0 === engine } }
            let start = HostClock.now + HostClock.ticks(Self.crossfadeLead)
            for engine in started {
                engine.scheduleRamp(from: 0, to: self.specs[engine.spec.key]?.gain ?? engine.spec.gain, startHost: start, seconds: Self.crossfadeSeconds)
            }
            for handoff in outgoing {
                handoff.engine.scheduleRamp(from: handoff.engine.currentGain, to: 0, startHost: start, seconds: Self.crossfadeSeconds)
            }
            try? await Task.sleep(for: .milliseconds(200))
            started.forEach(self.finishCrossfade)
            outgoing.forEach { self.retire($0.engine, fade: false) }
            for engine in started where engine.spec.kind != .app {
                self.restFailures.removeValue(forKey: engine.spec.deviceUID)
            }
            self.publishKeys()
        }
    }

    /// The crossfade is over: the engine follows gain changes again, starting with any made
    /// while it was starting.
    private func finishCrossfade(_ engine: TapEngine) {
        crossfading.remove(ObjectIdentifier(engine))
        let key = engine.spec.key
        guard engines[key] === engine, let gain = specs[key]?.gain,
              abs(gain - engine.currentTarget) > EngineDiff.gainTolerance else { return }
        engine.setGain(gain)
    }

    /// Tears an engine down on the HAL queue, by default after fading it out. The fade waits for
    /// the ramp to reach silence (after 40 ms it is still at 26%, and the stop would click), and
    /// the wait happens here, not on the serial HAL queue.
    private func retire(_ engine: TapEngine, fade: Bool = true) {
        let id = ObjectIdentifier(engine)
        guard live[id] != nil, retiring.insert(id).inserted else { return }
        crossfading.remove(id)
        if fade { engine.setGain(0) }
        Task { @MainActor in
            if fade { try? await Task.sleep(for: Self.fadeStopDelay) }
            _ = await self.hal { engine.stop() }
            self.live.removeValue(forKey: id)
            self.retiring.remove(id)
        }
    }

    /// Runs HAL work; the watchdog shows the "stuck" notice while a call takes too long.
    private func hal(_ work: @escaping @Sendable () throws -> Void) async -> HALQueue.Outcome {
        pendingHAL += 1
        updateWatchdog()
        let outcome = await HALQueue.shared.run(work)
        pendingHAL -= 1
        if pendingHAL == 0, halStuck {
            halStuck = false
            refreshState()
        }
        updateWatchdog()
        return outcome
    }

    /// A failed start holds the key back for `failureBackoff`, then it is tried again. A
    /// superseded engine failing (its device went away meanwhile) doesn't count: it must not hold
    /// back the engine that replaced it.
    private func recordFailure(_ key: String, engine: TapEngine) {
        guard engines[key] === engine else { return }
        failureTimes[key] = Date()
        scheduleRetry(after: Self.failureBackoff)
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds + 0.1))
            self?.publishKeys()
            self?.requestReconcile()
        }
    }

    private func publishKeys() {
        let active = Set(engines.keys)
        if active != activeKeys { activeKeys = active }
        let now = Date()
        failureTimes = failureTimes.filter { now.timeIntervalSince($0.value) < Self.failureBackoff }
        let failed = Set(failureTimes.keys)
        if failed != failedKeys { failedKeys = failed }
        updateWatchdog()
    }

    private func refreshState() {
        let new: State = permissionMissing ? .needsPermission : (halStuck ? .stuck : .ok)
        if new != state { state = new }
    }

    // MARK: - Watchdog

    /// Runs only while there is something to watch.
    private func updateWatchdog() {
        let needed = !engines.isEmpty || !failedKeys.isEmpty || pendingHAL > 0 || permissionMissing
        if needed, watchdog == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.25
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        } else if !needed, let timer = watchdog {
            timer.invalidate()
            watchdog = nil
        }
    }

    private func tick() {
        watchdogTicks &+= 1
        let stuck = pendingHAL > 0 && HALQueue.shared.busySeconds > Self.halStuckAfter
        if stuck != halStuck {
            halStuck = stuck
            if stuck { engineLog.error("a HAL call has been running for over \(Int(Self.halStuckAfter)) s") }
            refreshState()
        }
        // Access can be granted or revoked in System Settings at any time.
        if watchdogTicks % 5 == 0, permissionMissing || !engines.isEmpty { PermissionService.shared.refresh() }
        restartIdleEngines()
        if !failedKeys.isEmpty { publishKeys() }
        updateWatchdog()
    }

    /// Restarts the IO of engines that have been silent, so the Mac can sleep.
    private func restartIdleEngines() {
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
                engineLog.debug("\(key, privacy: .public): idle for \(Int(silentFor)) s, restarting IO")
                Task { @MainActor in
                    if case .failed(let message) = await self.hal({ try engine.restartIO() }), self.engines[key] === engine {
                        engineLog.error("\(key, privacy: .public): \(message, privacy: .public), rebuilding")
                        self.requestRebuild([key])
                    }
                }
            } else if silentFor < 1 {
                idleRestarts.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Recovery and shutdown

    /// A device's sample rate changed: its aggregates went silent, so rebuild their engines.
    func rebuildEngines(onDevice uid: String) {
        streamIndexCache.removeValue(forKey: uid)
        let keys = specs.filter { $0.value.deviceUID == uid }.map(\.key)
        guard !keys.isEmpty else { return }
        engineLog.notice("rebuilding \(keys.count) engine(s) on \(uid, privacy: .private(mask: .hash))")
        requestRebuild(keys)
    }

    /// After wake, devices may have been reset: rebuild every engine once things settle, new
    /// before old so controlled apps are never heard unprocessed.
    func handleWake() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            engineLog.notice("rebuilding \(self.specs.count) engine(s) after wake")
            DeviceService.shared.refresh()
            AppAudioService.shared.refresh()
            self.requestRebuild(self.specs.keys)
        }
    }

    /// coreaudiod restarted: every tap and aggregate is gone. Drop them and build again.
    func handleServiceRestart() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.restartAll()
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

    /// Tears every engine down and rebuilds from scratch ("Restart audio engine" in Settings,
    /// coreaudiod restart).
    func restartAll() {
        generation += 1
        inFlight = 0
        reconcileDeferred = false
        pendingRebuild = []
        let old = Array(live.values)
        engines = [:]
        specs = [:]
        crossfading = []
        forwardTo = [:]
        failureTimes = [:]
        restFailures = [:]
        idleRestarts = [:]
        streamIndexCache = [:]
        ownProcessObjectID = nil
        old.forEach { retire($0) }
        publishKeys()
        refreshState()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            self.reconcile()
        }
    }

    /// Synchronous teardown on quit, capped at 2 s. Private taps also vanish with the process.
    func shutdown() {
        let all = Array(live.values)
        live = [:]
        engines = [:]
        specs = [:]
        watchdog?.invalidate()
        watchdog = nil
        guard !all.isEmpty else { return }
        HALQueue.shared.runAndWait(timeout: 2) {
            for engine in all { engine.stop() }
        }
    }

    /// Diagnostics lines for `--dump-audio`.
    func diagnostics() -> [String] {
        specs.keys.sorted().compactMap { key in
            guard let spec = specs[key] else { return nil }
            let engine = engines[key]
            return "  \(key): \(spec.kind) device=\(spec.deviceUID) gain=\(spec.gain) processes=\(spec.processObjectIDs) follows=\(spec.bundleIDs) callbacks=\(engine?.stats.callbacks ?? 0)"
        }
    }
}

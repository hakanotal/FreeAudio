import AppKit
import CoreAudio

/// The apps currently playing audio, with their helper processes grouped under them.
@MainActor
final class AppAudioService: ObservableObject, @unchecked Sendable {
    static let shared = AppAudioService()
    private init() {}

    /// The app list: every open regular app (with a Dock presence) that is an audio client, playing
    /// or not, plus background processes while they play (and `rowGrace` after). Sorted by name.
    @Published private(set) var apps: [AudioApp] = []
    /// Every grouped audio client, playing or not. `TapService` follows this list.
    @Published private(set) var allApps: [AudioApp] = []

    /// Faster polling while the panel is open. Listeners for `IsRunningOutput` don't always fire,
    /// so the poll is the backstop that keeps rows accurate.
    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            schedulePoll()
            if panelVisible { refresh() }
        }
    }

    private static let rowGrace: TimeInterval = 3
    private var lastPlaying: [String: Date] = [:]
    private var icons: [String: NSImage] = [:]
    private var processListListener: PropertyListener?
    private var processListeners: [AudioObjectID: [PropertyListener]] = [:]
    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// What stays the same for a process's whole life, read once per process object. Core Audio
    /// reuses object IDs (LESSONS), so an entry only counts while its PID still matches.
    private struct ProcessFacts {
        let pid: Int32
        let bundleID: String?
        let executablePath: String?
        let responsiblePID: Int32?
    }
    private var facts: [AudioObjectID: ProcessFacts] = [:]
    /// AppKit lookups, memoized until an app launches or quits (when their answers can change).
    /// Most processes are helpers that miss; a miss is only trusted for `missLifetime`, since a
    /// process may not have checked in with LaunchServices yet. (A top-level app that isn't
    /// registered yet still resolves through its bundle path.)
    private var appsByPID: [Int32: AppInfo] = [:]
    private var pidMisses: [Int32: Date] = [:]
    private var appsByBundlePath: [String: AppInfo] = [:]
    private static let missLifetime: TimeInterval = 10
    /// Bundle IDs of running regular apps (Dock presence), listed while open, playing or not.
    private var regularAppIDs: Set<String> = []

    func start() {
        guard processListListener == nil else { return }
        processListListener = PropertyListener(object: AudioObjectID(kAudioObjectSystemObject),
                                               address: CoreAudioAddress.processObjectList) { [weak self] in
            self?.scheduleRefresh()
        }
        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.runningAppsChanged() }
                })
            }
        }
        updateRegularApps()
        schedulePoll()
        refresh()
    }

    private func schedulePoll() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: panelVisible ? 1 : 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = panelVisible ? 0.2 : 1
        pollTimer = timer
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            // Short: a new audio process of a controlled app plays unprocessed until its tap exists.
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// An app launched or quit: AppKit's answers about processes may have changed.
    private func runningAppsChanged() {
        appsByPID = [:]
        pidMisses = [:]
        appsByBundlePath = [:]
        updateRegularApps()
        scheduleRefresh()
    }

    private func updateRegularApps() {
        regularAppIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier))
    }

    func refresh() {
        let processes = (try? AudioHardwareSystem.shared.processes) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let knownUIDs = Dictionary(DeviceService.shared.outputDevices.map { ($0.objectID, $0.uid) }, uniquingKeysWith: { first, _ in first })
        var records: [ProcessRecord] = []
        var seen = Set<AudioObjectID>()
        for process in processes {
            guard let pid = try? process.pid else { continue }
            let id = process.id
            seen.insert(id)
            let fact: ProcessFacts
            if let cached = facts[id], cached.pid == pid {
                fact = cached
            } else {
                fact = ProcessFacts(pid: pid, bundleID: (try? process.bundleID) ?? nil,
                                    executablePath: executablePath(forPID: pid),
                                    responsiblePID: PrivateAPI.responsiblePID(for: pid))
                facts[id] = fact
                // A new process, or Core Audio reused the ID: listen to this one. FreeAudio's own
                // process changes devices on every engine start and stop; it never needs a refresh.
                if pid == ownPID {
                    processListeners.removeValue(forKey: id)?.forEach { $0.cancel() }
                } else {
                    attachListeners(to: id)
                }
            }
            records.append(ProcessRecord(
                objectID: id,
                pid: pid,
                bundleID: fact.bundleID,
                isRunningOutput: (try? process.isRunningOutput) ?? false,
                executablePath: fact.executablePath,
                responsiblePID: fact.responsiblePID,
                outputDeviceUIDs: Self.outputDeviceUIDs(of: process, known: knownUIDs)
            ))
        }
        for id in facts.keys where !seen.contains(id) {
            facts.removeValue(forKey: id)
            processListeners.removeValue(forKey: id)?.forEach { $0.cancel() }
        }
        let referencedPIDs = Set(records.map(\.pid) + records.compactMap(\.responsiblePID))
        appsByPID = appsByPID.filter { referencedPIDs.contains($0.key) }
        pidMisses = pidMisses.filter { referencedPIDs.contains($0.key) }

        let grouped = AppGrouping.group(records, ownPID: ownPID, appForPID: appInfo(forPID:), appForBundlePath: appInfo(forBundlePath:))
        if grouped != allApps {
            allApps = grouped
            let ids = Set(grouped.map(\.id))
            icons = icons.filter { ids.contains($0.key) }
        }
        let now = Date()
        for app in grouped where app.isPlaying { lastPlaying[app.id] = now }
        // Regular apps that have connected to the audio system stay listed while they're open, so
        // their level can be set before they make a sound. Daemons, menu bar agents and CLI tools
        // (Control Center, dictation, afplay...) only show while they play, or they'd clutter it.
        let visible = grouped.filter { app in
            app.isPlaying
                || app.bundleID.map(regularAppIDs.contains) == true
                || lastPlaying[app.id].map { now.timeIntervalSince($0) < Self.rowGrace } == true
        }
        lastPlaying = lastPlaying.filter { now.timeIntervalSince($0.value) < Self.rowGrace }
        if visible != apps { apps = visible }
    }

    /// The devices a process plays to. Read in the output scope: the property's scope selects
    /// the input or output list, and an app in a call also uses its microphone's device.
    private static func outputDeviceUIDs(of process: AudioHardwareProcess, known: [AudioObjectID: String]) -> [String] {
        guard let data = try? process.propertyData(address: CoreAudioAddress.processOutputDevices) else { return [] }
        let count = data.count / MemoryLayout<AudioObjectID>.size
        return data.withUnsafeBytes { raw in
            (0..<count).compactMap { index in
                let id = raw.loadUnaligned(fromByteOffset: index * MemoryLayout<AudioObjectID>.size, as: AudioObjectID.self)
                return known[id] ?? (try? AudioHardwareDevice(id: id).uid)
            }
        }
    }

    /// `IsRunningOutput` (starts and stops) and output `Devices` (the app moved to another device,
    /// e.g. after a default-output change) of one process object.
    private func attachListeners(to id: AudioObjectID) {
        processListeners.removeValue(forKey: id)?.forEach { $0.cancel() }
        processListeners[id] = [CoreAudioAddress.processIsRunningOutput, CoreAudioAddress.processOutputDevices].compactMap { address in
            PropertyListener(object: id, address: address) { [weak self] in self?.scheduleRefresh() }
        }
    }

    /// Re-registers every listener (after coreaudiod restarted: every object ID is new) and refreshes.
    func restartListeners() {
        processListListener?.cancel()
        processListListener = nil
        processListeners.values.forEach { $0.forEach { $0.cancel() } }
        processListeners = [:]
        facts = [:]
        start()
    }

    // MARK: - AppKit lookups

    private func appInfo(forPID pid: Int32) -> AppInfo? {
        if let cached = appsByPID[pid] { return cached }
        if let miss = pidMisses[pid], Date().timeIntervalSince(miss) < Self.missLifetime { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid),
              let url = app.bundleURL, url.pathExtension == "app",
              let bundleID = app.bundleIdentifier else {
            pidMisses[pid] = Date()
            return nil
        }
        let info = AppInfo(bundleID: bundleID, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                           pid: pid, bundlePath: url.path)
        appsByPID[pid] = info
        return info
    }

    private func appInfo(forBundlePath path: String) -> AppInfo? {
        if let cached = appsByBundlePath[path] { return cached }
        guard let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let name = running?.localizedName
            ?? FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        let info = AppInfo(bundleID: bundleID, name: name, pid: running?.processIdentifier, bundlePath: path)
        appsByBundlePath[path] = info
        return info
    }

    /// App icon for a row (cached per app).
    func icon(for app: AudioApp) -> NSImage {
        if let cached = icons[app.id] { return cached }
        let image: NSImage
        if let pid = app.appPID, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            image = icon
        } else if let path = app.bundlePath {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        icons[app.id] = image
        return image
    }
}

import AppKit
import CoreAudio

/// The apps currently playing audio, with their helper processes grouped under them.
@MainActor
final class AppAudioService: ObservableObject, @unchecked Sendable {
    static let shared = AppAudioService()
    private init() {}

    /// Apps playing audio (or that stopped less than `rowGrace` ago), sorted by name.
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
    private var runningListeners: [AudioObjectID: PropertyListener] = [:]
    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard processListListener == nil else { return }
        processListListener = PropertyListener(object: AudioObjectID(kAudioObjectSystemObject),
                                               address: CoreAudioAddress.processObjectList) { [weak self] in
            self?.scheduleRefresh()
        }
        schedulePoll()
        refresh()
    }

    private func schedulePoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: panelVisible ? 1 : 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        let processes = (try? AudioHardwareSystem.shared.processes) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var records: [ProcessRecord] = []
        for process in processes {
            guard let pid = try? process.pid else { continue }
            records.append(ProcessRecord(
                objectID: process.id,
                pid: pid,
                bundleID: (try? process.bundleID) ?? nil,
                isRunningOutput: (try? process.isRunningOutput) ?? false,
                executablePath: executablePath(forPID: pid),
                responsiblePID: PrivateAPI.responsiblePID(for: pid),
                outputDeviceUIDs: ((try? process.devices) ?? []).compactMap { try? $0.uid }
            ))
        }
        updateRunningListeners(for: Set(processes.map(\.id)))

        let grouped = AppGrouping.group(records, ownPID: ownPID, appForPID: Self.appInfo(forPID:), appForBundlePath: Self.appInfo(forBundlePath:))
        if grouped != allApps { allApps = grouped }
        let now = Date()
        for app in grouped where app.isPlaying { lastPlaying[app.id] = now }
        let visible = grouped.filter { app in
            app.isPlaying || lastPlaying[app.id].map { now.timeIntervalSince($0) < Self.rowGrace } == true
        }
        lastPlaying = lastPlaying.filter { now.timeIntervalSince($0.value) < Self.rowGrace }
        if visible != apps { apps = visible }
    }

    /// One `IsRunningOutput` listener per process object, added and removed as processes come and go.
    private func updateRunningListeners(for objectIDs: Set<AudioObjectID>) {
        for id in runningListeners.keys where !objectIDs.contains(id) {
            runningListeners.removeValue(forKey: id)?.cancel()
        }
        for id in objectIDs where runningListeners[id] == nil {
            runningListeners[id] = PropertyListener(object: id, address: CoreAudioAddress.processIsRunningOutput) { [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    // MARK: - AppKit lookups

    private static func appInfo(forPID pid: Int32) -> AppInfo? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let url = app.bundleURL, url.pathExtension == "app",
              let bundleID = app.bundleIdentifier else { return nil }
        return AppInfo(bundleID: bundleID, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                       pid: pid, bundlePath: url.path)
    }

    private static func appInfo(forBundlePath path: String) -> AppInfo? {
        guard let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let name = running?.localizedName
            ?? FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        return AppInfo(bundleID: bundleID, name: name, pid: running?.processIdentifier, bundlePath: path)
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

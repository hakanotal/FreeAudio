import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than by a view, so audio work runs even if the menu panel is never
    /// opened (MenuBarExtra builds its content lazily).
    let audioManager: AudioManager
    private var workspaceObservers: [NSObjectProtocol] = []
    private var audioStarted = false

    override init() {
        // Must run before any service reads its defaults.
        SettingsService.migrateLegacyDefaults()
        audioManager = AudioManager()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `FreeAudio --dump-audio`: print a read-only diagnostics snapshot and quit. Runs next to
        // a normal instance, so it skips the single-instance check and the launch agent.
        if CommandLine.arguments.contains("--dump-audio") {
            audioManager.start(engines: false)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                print(self.audioManager.diagnostics())
                NSApp.terminate(nil)
            }
            return
        }

        // Prevent duplicate launches: exit if another instance is already running
        let otherInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        // Started by the launchd agent (login / crash restart / hand-over), or the new version an
        // update just installed: replace the running copy so this one keeps running.
        let replacesOthers = LaunchService.isManagedLaunch || UpdateService.isRelaunchAfterUpdate
        if replacesOthers {
            otherInstances.forEach { $0.terminate() }
        }

        Task { @MainActor in
            // A quitting instance tears down its process taps; wait until it is gone before
            // starting audio work (taps from two processes on the same device interfere). A
            // manual launch also waits briefly: the other copy may be quitting, or be a
            // short-lived `--dump-audio` run.
            await Self.waitForTermination(of: otherInstances, timeout: replacesOthers ? 5 : 2)
            if !replacesOthers, otherInstances.contains(where: Self.isAlive) {
                print("[FreeAudio] Another instance is already running, exiting.")
                NSApp.terminate(nil)
                return
            }
            self.startServices()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        VolumeKeyService.shared.stop()
        SettingsService.shared.flushPendingSaves()
        // Destroy taps and aggregate devices before exiting (they'd also vanish with the process).
        TapService.shared.shutdown()
    }

    // MARK: - Startup

    private func startServices() {
        // A copy started by the updater keeps running: handing it over to the agent now would
        // have launchd start the newly written app, which macOS refuses the first time (Launch
        // Constraint Violation). The agent starts the new version from the next login.
        if UpdateService.isRelaunchAfterUpdate {
            SettingsService.shared.launchAtLogin = LaunchService.shared.isEnabled
            startAudio()
            return
        }
        // Migrate the old login item / hand a manual launch over to the launchd agent.
        let handedOver = LaunchService.shared.prepareAtLaunch()
        SettingsService.shared.launchAtLogin = LaunchService.shared.isEnabled

        if handedOver {
            // The agent's instance replaces this one in a moment. Starting audio here would have
            // two processes tap the same apps; only fall back if the hand-over didn't happen.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                self.startAudio()
            }
            return
        }
        startAudio()
    }

    private func startAudio() {
        guard !audioStarted else { return }
        audioStarted = true
        audioManager.start()

        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.audioManager.handleWake()
                // The app may have been moved while it ran; keep launch at login pointing at it.
                LaunchService.shared.repairAgentPathIfNeeded()
            }
        })

        if SettingsService.shared.checkUpdatesOnLaunch {
            Task { await UpdateService.shared.checkForUpdates() }
        }
        UpdateService.shared.startPeriodicChecks()
    }

    private static func waitForTermination(of apps: [NSRunningApplication], timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while apps.contains(where: isAlive), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Asks the kernel, not `NSRunningApplication.isTerminated`: that flag lagged seconds behind
    /// the exit while this loop polled it, so a copy that quit in 0.3 s still cost the full wait.
    private static func isAlive(_ app: NSRunningApplication) -> Bool {
        kill(app.processIdentifier, 0) == 0 || errno == EPERM
    }
}

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than by a view, so audio work runs even if the menu panel is never
    /// opened (MenuBarExtra builds its content lazily).
    let audioManager: AudioManager

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
            audioManager.start()
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
        var replacedInstances: [NSRunningApplication] = []
        if !otherInstances.isEmpty {
            if LaunchService.isManagedLaunch {
                // Started by the launchd agent (login / crash restart / hand-over): replace the
                // manually opened copy so the supervised instance is the one that keeps running.
                otherInstances.forEach { $0.terminate() }
                replacedInstances = otherInstances
            } else {
                print("[FreeAudio] Another instance is already running, exiting.")
                NSApp.terminate(nil)
                return
            }
        }

        Task { @MainActor in
            // A quitting instance tears down its process taps. Wait until it is gone before
            // starting audio work: taps from two processes on the same device interfere.
            await Self.waitForTermination(of: replacedInstances, timeout: 5)
            self.startServices()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsService.shared.flushAppSettings()
        // Destroy taps and aggregate devices before exiting (they'd also vanish with the process).
        TapService.shared.shutdown()
    }

    // MARK: - Startup

    private func startServices() {
        // Migrate the old login item / hand a manual launch over to the launchd agent.
        LaunchService.shared.prepareAtLaunch()
        SettingsService.shared.launchAtLogin = LaunchService.shared.isEnabled

        audioManager.start()
    }

    private static func waitForTermination(of apps: [NSRunningApplication], timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

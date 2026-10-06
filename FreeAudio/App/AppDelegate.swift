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

    // MARK: - Startup

    private func startServices() {
        // Migrate the old login item / hand a manual launch over to the launchd agent.
        LaunchService.shared.prepareAtLaunch()
        SettingsService.shared.launchAtLogin = LaunchService.shared.isEnabled

        audioManager.start()

        // `FreeAudio --dump-audio`: print a diagnostics snapshot and quit.
        if CommandLine.arguments.contains("--dump-audio") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                print(self.audioManager.diagnostics())
                NSApp.terminate(nil)
            }
        }
    }

    private static func waitForTermination(of apps: [NSRunningApplication], timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

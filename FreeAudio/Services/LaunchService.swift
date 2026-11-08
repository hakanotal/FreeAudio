import Foundation
import os
import ServiceManagement

/// Manages "Launch at Login" via a per-user launchd agent (~/Library/LaunchAgents).
///
/// Besides starting FreeAudio at login, the agent restarts it after a crash:
/// `KeepAlive.SuccessfulExit = false` relaunches on a non-zero exit or a signal, while a
/// normal Quit (exit 0) is left alone. launchd throttles restarts (ThrottleInterval).
@MainActor
final class LaunchService: @unchecked Sendable {
    static let shared = LaunchService()
    private init() {}

    static let agentLabel = "com.freeaudio.app.agent"
    /// Passed by the agent so a launchd-started instance can be told apart from a manual launch.
    static let managedLaunchArgument = "--launchd"

    /// True when launchd started this process (login or crash restart).
    static var isManagedLaunch: Bool {
        CommandLine.arguments.contains(managedLaunchArgument)
    }

    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.agentLabel).plist")
    }

    private var domain: String { "gui/\(getuid())" }
    private var job: String { "\(domain)/\(Self.agentLabel)" }

    // MARK: - State

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    // MARK: - Enable / Disable

    @discardableResult
    func enable() -> Bool {
        guard writeAgentPlist() else { return false }
        if Self.isManagedLaunch {
            // Already supervised by launchd; just make sure the job isn't disabled.
            launchctl("enable", job)
        } else {
            handOverToAgent(reload: true)
        }
        return true
    }

    @discardableResult
    func disable() -> Bool {
        launchctl("disable", job)
        // Booting out the job would also kill this process if launchd started it;
        // in that case the loaded job just ends at logout.
        if !Self.isManagedLaunch {
            launchctl("bootout", job)
        }
        try? FileManager.default.removeItem(at: agentURL)
        return !isEnabled
    }

    /// Toggle and return the new state.
    @discardableResult
    func toggle() -> Bool {
        if isEnabled {
            disable()
            return false
        } else {
            enable()
            return true
        }
    }

    // MARK: - Launch-time Sync

    /// Called once at launch: migrates the old SMAppService login item to the agent, keeps the
    /// agent pointing at the current app location, and hands a manually opened copy over to
    /// launchd so crash restarts cover it.
    /// Returns true when this manually opened instance handed over to the launchd agent, whose
    /// instance will replace it shortly.
    @discardableResult
    func prepareAtLaunch() -> Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            return enable() && !Self.isManagedLaunch
        }
        guard isEnabled else { return false }
        let moved = agentNeedsRepair
        if moved {
            // A managed launch only rewrites the file; launchd reads it at the next login.
            writeAgentPlist()
        }
        if !Self.isManagedLaunch {
            handOverToAgent(reload: moved)
            return true
        }
        return false
    }

    /// Keeps the agent pointing at this copy when the app was moved while it runs (checked after
    /// wake). Only the file changes: launchd reads it at the next login, and reloading the job
    /// would end this process.
    func repairAgentPathIfNeeded() {
        guard isEnabled, agentNeedsRepair, writeAgentPlist() else { return }
        Self.log.notice("Launch agent now points at the app's current location")
    }

    // MARK: - Helpers

    private static let log = Logger(subsystem: "com.freeaudio.app", category: "launch")

    /// Where the executable is now, for the agent to start. `Bundle.main.executablePath` keeps the
    /// launch-time path after the app (or a folder above it) is moved; `proc_pidpath` follows the
    /// move. nil for a translocated copy (opened from Downloads or a quarantined image): it runs
    /// from a temporary path that must never be written into the agent.
    private var agentExecutablePath: String? {
        guard let path = executablePath(forPID: getpid()) ?? Bundle.main.executablePath,
              !path.contains("/AppTranslocation/") else { return nil }
        return path
    }

    /// The agent starts another path (the app moved), or its plist is unreadable.
    private var agentNeedsRepair: Bool {
        guard let current = agentExecutablePath else { return false }
        return agentProgramPath() != current
    }

    /// Starts the agent so launchd runs a supervised instance; that instance then takes over
    /// from this manually opened one (see AppDelegate). Never called from a launchd-started process.
    private func handOverToAgent(reload: Bool) {
        launchctl("enable", job)
        if reload {
            launchctl("bootout", job)
        }
        // kickstart if the job is already loaded; otherwise bootstrap it (RunAtLoad starts it).
        if !launchctl("kickstart", job) {
            launchctl("bootstrap", domain, agentURL.path)
        }
    }

    @discardableResult
    private func writeAgentPlist() -> Bool {
        guard let executable = agentExecutablePath else { return false }
        let plist: [String: Any] = [
            "Label": Self.agentLabel,
            "ProgramArguments": [executable, Self.managedLaunchArgument],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "ThrottleInterval": 10,
        ]
        do {
            try FileManager.default.createDirectory(
                at: agentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
            return true
        } catch {
            Self.log.error("Writing the launch agent failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func agentProgramPath() -> String? {
        guard let data = try? Data(contentsOf: agentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return nil }
        return arguments.first
    }

    /// Runs `/bin/launchctl` synchronously (it returns immediately) and reports success.
    @discardableResult
    private func launchctl(_ arguments: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

import AppKit

/// System Audio Recording permission, which process taps need. Checked with the private
/// `TCCAccessPreflight` (approved 2026-10-06) so FreeAudio never creates a tap that would silence
/// an app because access was denied.
@MainActor
final class PermissionService: ObservableObject, @unchecked Sendable {
    static let shared = PermissionService()
    private init() {
        status = PrivateAPI.audioCaptureStatus()
    }

    @Published private(set) var status: PrivateAPI.AudioCaptureStatus
    private var requestInFlight = false

    /// Taps may be created. `unavailable` (the private function is missing) is treated as allowed;
    /// `TapService` then relies on its silence check.
    var allowsTaps: Bool { status == .authorized || status == .unavailable }

    func refresh() {
        let current = PrivateAPI.audioCaptureStatus()
        if current != status { status = current }
    }

    /// Shows the macOS prompt if the user hasn't answered it yet. Called on every reconcile that
    /// needs taps, so it only asks tccd while the answer is still open.
    func requestIfNeeded() {
        guard status == .notDetermined, !requestInFlight else { return }
        refresh()
        guard status == .notDetermined else { return }
        requestInFlight = true
        let started = PrivateAPI.requestAudioCapture { granted in
            engineLog.notice("System Audio Recording request answered: \(granted)")
            Task { @MainActor in
                PermissionService.shared.requestInFlight = false
                PermissionService.shared.refresh()
            }
        }
        engineLog.notice("System Audio Recording requested (started: \(started))")
        if !started { requestInFlight = false }
    }

    /// `tccutil reset <service> <this app's bundle ID>`: clears only FreeAudio's own record, so
    /// macOS asks again. Used for records an earlier build with another signature left behind
    /// (every ad-hoc build): they keep failing ("Failed to match existing code requirement")
    /// even after the user turns FreeAudio on in System Settings.
    static func resetOwnRecord(_ service: String) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()  // returns at once
        } catch {
            engineLog.error("tccutil reset \(service, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens System Settings → Privacy & Security → Screen & System Audio Recording.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

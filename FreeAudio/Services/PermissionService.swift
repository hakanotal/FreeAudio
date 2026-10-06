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

    /// Shows the macOS prompt if the user hasn't answered it yet. Called when a tap is first needed.
    func requestIfNeeded() {
        refresh()
        guard status == .notDetermined, !requestInFlight else { return }
        requestInFlight = true
        let started = PrivateAPI.requestAudioCapture { _ in
            Task { @MainActor in
                PermissionService.shared.requestInFlight = false
                PermissionService.shared.refresh()
            }
        }
        if !started { requestInFlight = false }
    }

    /// Opens System Settings → Privacy & Security → Screen & System Audio Recording.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

import Combine
import Foundation

/// Wires the audio services together. Owned by `AppDelegate`, so it runs whether or not the
/// panel has been opened (MenuBarExtra builds its content lazily).
@MainActor
final class AudioManager: ObservableObject, @unchecked Sendable {
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        let devices = DeviceService.shared
        devices.start()
        AppAudioService.shared.start()
        TapService.shared.start()

        // Device volume follows the default output.
        devices.$outputDevices
            .combineLatest(devices.$defaultOutputUID)
            .receive(on: RunLoop.main)
            .sink { outputDevices, defaultUID in
                DeviceVolumeService.shared.bind(to: outputDevices.first { $0.uid == defaultUID })
            }
            .store(in: &cancellables)
    }

    /// Plain-text snapshot of devices, volume and app grouping (`FreeAudio --dump-audio`).
    func diagnostics() -> String {
        let devices = DeviceService.shared
        let volume = DeviceVolumeService.shared
        var lines = ["FreeAudio \(UpdateService.shared.currentVersion) diagnostics", "", "Output devices:"]
        for device in devices.outputDevices {
            let isDefault = device.uid == devices.defaultOutputUID ? " [default]" : ""
            lines.append("  \(device.name)\(isDefault) uid=\(device.uid) transport=\(device.transport) hardwareVolume=\(device.hasHardwareVolume)")
        }
        lines.append("Default output volume: \(Int((volume.volume * 100).rounded()))% muted=\(volume.isMuted) canMute=\(volume.canMute) tier=\(volume.tier)")
        lines.append("System Audio Recording: \(PermissionService.shared.status)")
        lines.append("")
        lines.append("Tap engines (\(TapService.shared.state)):")
        lines.append(contentsOf: TapService.shared.diagnostics())
        lines.append("Saved app settings: \(SettingsService.shared.appSettings.map { "\($0.key)=\(Int(($0.value.volume * 100).rounded()))%\($0.value.muted ? " muted" : "")\($0.value.boost > 1 ? " boost \($0.value.boost)" : "")" }.sorted())")
        lines.append("")
        lines.append("Audio clients grouped into apps (playing first):")
        let apps = AppAudioService.shared.allApps.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
        for app in apps {
            lines.append("  \(app.isPlaying ? "▶" : " ") \(app.name) id=\(app.id) pids=\(app.pids) objects=\(app.processObjectIDs)"
                + (app.helperBundleIDs.isEmpty ? "" : " helpers=\(app.helperBundleIDs)")
                + (app.outputDeviceUIDs.isEmpty ? "" : " devices=\(app.outputDeviceUIDs)"))
        }
        return lines.joined(separator: "\n")
    }
}

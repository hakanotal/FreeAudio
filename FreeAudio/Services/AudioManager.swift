import Combine
import Foundation

/// Wires the audio services together. Owned by `AppDelegate`, so it runs whether or not the
/// panel has been opened (MenuBarExtra builds its content lazily).
@MainActor
final class AudioManager: ObservableObject, @unchecked Sendable {
    private var cancellables: Set<AnyCancellable> = []

    /// - Parameter engines: false for the read-only `--dump-audio` instance, which runs next to
    ///   the normal one and must never create taps of its own.
    func start(engines: Bool = true) {
        let devices = DeviceService.shared
        devices.start()
        AppAudioService.shared.start()
        if engines { TapService.shared.start() }

        // Device volume follows the default output.
        devices.$outputDevices
            .combineLatest(devices.$defaultOutputUID)
            .receive(on: RunLoop.main)
            .sink { outputDevices, defaultUID in
                DeviceVolumeService.shared.bind(to: outputDevices.first { $0.uid == defaultUID })
            }
            .store(in: &cancellables)

        guard engines else { return }
        startVolumeKeys()
        let taps = TapService.shared
        devices.sampleRateChanged
            .sink { uid in taps.rebuildEngines(onDevice: uid) }
            .store(in: &cancellables)
        devices.serviceRestarted
            .sink { _ in
                // Every object ID and listener died with coreaudiod.
                DeviceService.shared.restartListeners()
                AppAudioService.shared.restartListeners()
                taps.handleServiceRestart()
            }
            .store(in: &cancellables)
    }

    /// Volume keys: handled only while the default output uses software volume (no hardware
    /// control); otherwise they pass through and macOS behaves as usual.
    private func startVolumeKeys() {
        let keys = VolumeKeyService.shared
        keys.handler = { key, isRepeat, modifiers in
            let volume = DeviceVolumeService.shared
            guard volume.tier == .software, volume.deviceUID != nil else { return false }
            // Like macOS: 16 steps, Option+Shift for quarter steps.
            let fine = modifiers.contains(.option) && modifiers.contains(.shift)
            let step = fine ? 1.0 / 64 : 1.0 / 16
            switch key {
            case .volumeUp: volume.step(by: step)
            case .volumeDown: volume.step(by: -step)
            case .mute:
                if isRepeat { return true }
                volume.setMuted(!volume.isMuted)
            }
            VolumeHUDService.shared.show(volume: volume.volume, muted: volume.isMuted, deviceName: volume.deviceName)
            return true
        }
        // The event tap needs Accessibility, so only start it once a software-volume output is
        // in use; it keeps running (passing keys through) afterwards.
        DeviceVolumeService.shared.$tier
            .receive(on: RunLoop.main)
            .sink { tier in
                guard tier == .software else { return }
                keys.requestTrustIfNeeded()
                keys.startIfNeeded()
            }
            .store(in: &cancellables)
    }

    /// Called by AppDelegate after the Mac wakes.
    func handleWake() {
        DeviceService.shared.refresh()
        AppAudioService.shared.refresh()
        TapService.shared.handleWake()
        // Event taps can come back from sleep enabled but inert: recreate it.
        let keys = VolumeKeyService.shared
        if keys.isRunning {
            keys.stop()
            keys.startIfNeeded()
        }
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
        // macOS judges a process started from a terminal by the terminal's grant, so this only
        // reflects FreeAudio's own permission when FreeAudio was opened normally.
        lines.append("System Audio Recording (this process): \(PermissionService.shared.status)")
        lines.append("")
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

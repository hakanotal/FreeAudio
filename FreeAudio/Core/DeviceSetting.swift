import Foundation

/// Saved per-device settings, keyed by device UID.
struct DeviceSetting: Codable, Equatable, Sendable {
    /// Software volume slider position 0–1 (gain follows `VolumeCurve`). Used on devices without
    /// a working hardware volume control (HDMI/DisplayPort monitors).
    var softwareVolume: Double = 1
    var softwareMuted = false
    /// Use software volume even though the device reports a hardware control (for devices whose
    /// hardware control doesn't actually change the level).
    var forceSoftware = false
    /// Display name, for diagnostics.
    var name: String?

    init(softwareVolume: Double = 1, softwareMuted: Bool = false, forceSoftware: Bool = false, name: String? = nil) {
        self.softwareVolume = softwareVolume
        self.softwareMuted = softwareMuted
        self.forceSoftware = forceSoftware
        self.name = name
    }

    /// Nothing to store: full software volume, not muted, no override.
    var isDefault: Bool {
        softwareVolume >= 0.999 && !softwareMuted && !forceSoftware
    }

    /// The software volume leaves audio untouched (no rest tap needed).
    var isUnity: Bool {
        softwareVolume >= 0.999 && !softwareMuted
    }

    /// Linear gain applied in software (0 when muted).
    var gain: Float {
        softwareMuted ? 0 : Float(VolumeCurve.gain(forSlider: softwareVolume))
    }

    private enum CodingKeys: String, CodingKey {
        case softwareVolume, softwareMuted, forceSoftware, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let volume = (try? container.decodeIfPresent(Double.self, forKey: .softwareVolume)) ?? 1
        softwareVolume = volume.isFinite ? min(max(volume, 0), 1) : 1
        softwareMuted = (try? container.decodeIfPresent(Bool.self, forKey: .softwareMuted)) ?? false
        forceSoftware = (try? container.decodeIfPresent(Bool.self, forKey: .forceSoftware)) ?? false
        name = try? container.decodeIfPresent(String.self, forKey: .name)
    }
}

/// The `devices.json` file.
struct DeviceSettingsFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var devices: [String: DeviceSetting] = [:]

    init(devices: [String: DeviceSetting] = [:]) {
        self.devices = devices
    }

    private enum CodingKeys: String, CodingKey {
        case version, devices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        devices = (try? container.decodeIfPresent([String: DeviceSetting].self, forKey: .devices)) ?? [:]
    }
}

/// Software volume plan for one device: the rest tap and the gains of the app engines on it.
enum SoftwareVolumePlan {
    /// Settings key of a device's rest engine.
    static func restKey(deviceUID: String) -> String { "rest:" + deviceUID }

    static func isRestKey(_ key: String) -> Bool { key.hasPrefix("rest:") }

    /// The rest engine for `deviceUID`: everything bound for the device except FreeAudio and the
    /// controlled apps. Ownership rule: every process it excludes must be in an app engine, so
    /// it excludes exactly the app engines' processes (and their followed bundle IDs, which
    /// covers relaunches) plus FreeAudio itself.
    static func restSpec(
        deviceUID: String,
        stream: UInt,
        deviceGain: Float,
        appSpecs: [EngineSpec],
        ownProcessObjectIDs: [UInt32],
        ownBundleID: String
    ) -> EngineSpec {
        var processes = Set(ownProcessObjectIDs)
        var bundleIDs: Set<String> = [ownBundleID]
        for spec in appSpecs where spec.kind == .app {
            processes.formUnion(spec.processObjectIDs)
            bundleIDs.formUnion(spec.bundleIDs)
        }
        return EngineSpec(
            key: restKey(deviceUID: deviceUID),
            kind: .rest(stream: stream),
            deviceUID: deviceUID,
            processObjectIDs: processes.sorted(),
            bundleIDs: bundleIDs.sorted(),
            gain: deviceGain)
    }

    /// App engines on a software-volume device also carry the device gain.
    static func applyDeviceGain(_ specs: inout [String: EngineSpec], deviceUID: String, deviceGain: Float) {
        for key in specs.keys where specs[key]?.kind == .app && specs[key]?.deviceUID == deviceUID {
            specs[key]?.gain *= deviceGain
        }
    }
}

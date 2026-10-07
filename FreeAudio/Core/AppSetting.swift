import Foundation

/// Saved per-app audio settings, keyed by `AudioApp.id` (bundle ID, or `exec:<name>`).
struct AppSetting: Codable, Equatable, Sendable {
    /// App level in percent, 0–200 (100 = unchanged). Gain follows `VolumeCurve.appGain`.
    var level: Double = 100
    var muted = false
    /// Display name, so the saved-settings list can show apps that aren't running.
    var name: String?
    /// Helper bundle IDs seen for this app (e.g. `com.google.Chrome.helper`), so a tap prepared
    /// before the app runs already follows its helpers.
    var helpers: [String]?
    /// Output device chosen for this app (device UID); nil follows the system default.
    var outputDeviceUID: String?
    /// That device's name, shown while it isn't connected.
    var outputDeviceName: String?

    init(level: Double = 100, muted: Bool = false, name: String? = nil, helpers: [String]? = nil,
         outputDeviceUID: String? = nil, outputDeviceName: String? = nil) {
        self.level = level
        self.muted = muted
        self.name = name
        self.helpers = helpers
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
    }

    /// At default settings an app is left alone (no tap). A chosen output device needs a tap even
    /// at 100%.
    var isDefault: Bool {
        abs(level - 100) < 0.05 && !muted && outputDeviceUID == nil
    }

    /// Linear gain the engine applies.
    var gain: Float {
        Float(VolumeCurve.appGain(forPercent: level))
    }

    // Tolerant decoding: missing keys take defaults and bad values are clamped, so an older or
    // hand-edited file never wipes the user's settings. v1.0 stored a slider `volume` (0–1) and a
    // `boost` multiplier; they convert to the level with the same gain.
    private enum CodingKeys: String, CodingKey {
        case level, muted, name, helpers, outputDeviceUID, outputDeviceName
        case volume, boost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let level = try? container.decodeIfPresent(Double.self, forKey: .level), level.isFinite {
            self.level = min(max(level, 0), VolumeCurve.maxAppPercent)
        } else {
            let volume = (try? container.decodeIfPresent(Double.self, forKey: .volume)).flatMap { $0 } ?? 1
            let boost = (try? container.decodeIfPresent(Double.self, forKey: .boost)).flatMap { $0 } ?? 1
            let gain = VolumeCurve.gain(forSlider: volume.isFinite ? volume : 1) * (boost.isFinite ? max(boost, 1) : 1)
            level = (VolumeCurve.appPercent(forGain: gain) * 10).rounded() / 10
        }
        muted = (try? container.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        helpers = try? container.decodeIfPresent([String].self, forKey: .helpers)
        let device = try? container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        outputDeviceUID = (device?.isEmpty ?? true) ? nil : device
        outputDeviceName = try? container.decodeIfPresent(String.self, forKey: .outputDeviceName)
    }
}

/// The `apps.json` file: a version plus settings per app.
struct AppSettingsFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var apps: [String: AppSetting] = [:]

    init(apps: [String: AppSetting] = [:]) {
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey {
        case version, apps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        apps = (try? container.decodeIfPresent([String: AppSetting].self, forKey: .apps)) ?? [:]
    }
}

extension AppSetting {
    /// Only the current keys are written (the old `volume`/`boost` keys are read-only).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(level, forKey: .level)
        try container.encode(muted, forKey: .muted)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(helpers, forKey: .helpers)
        try container.encodeIfPresent(outputDeviceUID, forKey: .outputDeviceUID)
        try container.encodeIfPresent(outputDeviceName, forKey: .outputDeviceName)
    }
}

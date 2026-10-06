import Foundation

/// Saved per-app audio settings, keyed by `AudioApp.id` (bundle ID, or `exec:<name>`).
struct AppSetting: Codable, Equatable, Sendable {
    /// Boost levels offered in the app detail (200% maximum).
    static let boostLevels: [Double] = [1, 1.5, 2]

    /// Slider position 0–1 (gain follows `VolumeCurve`).
    var volume: Double = 1
    var muted = false
    /// Gain multiplier on top of the slider: 1, 1.5 or 2.
    var boost: Double = 1
    /// Display name, so the saved-settings list can show apps that aren't running.
    var name: String?
    /// Helper bundle IDs seen for this app (e.g. `com.google.Chrome.helper`), so a tap prepared
    /// before the app runs already follows its helpers.
    var helpers: [String]?

    init(volume: Double = 1, muted: Bool = false, boost: Double = 1, name: String? = nil, helpers: [String]? = nil) {
        self.volume = volume
        self.muted = muted
        self.boost = boost
        self.name = name
        self.helpers = helpers
    }

    /// At default settings an app is left alone (no tap).
    var isDefault: Bool {
        volume >= 0.999 && !muted && boost <= 1.0001
    }

    /// Linear gain the engine applies.
    var gain: Float {
        Float(VolumeCurve.gain(forSlider: volume) * boost)
    }

    // Tolerant decoding: missing keys take defaults and bad values are clamped, so an older or
    // hand-edited file never wipes the user's settings.
    private enum CodingKeys: String, CodingKey {
        case volume, muted, boost, name, helpers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let volume = (try? container.decodeIfPresent(Double.self, forKey: .volume)) ?? 1
        self.volume = volume.isFinite ? min(max(volume, 0), 1) : 1
        muted = (try? container.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        let boost = (try? container.decodeIfPresent(Double.self, forKey: .boost)) ?? 1
        self.boost = Self.boostLevels.min { abs($0 - boost) < abs($1 - boost) } ?? 1
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        helpers = try? container.decodeIfPresent([String].self, forKey: .helpers)
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

import Foundation
import Combine
import Observation
import os

private let settingsLog = Logger(subsystem: "com.freeaudio.app", category: "settings")

/// Centralized settings persistence service.
/// Simple settings use UserDefaults via @AppStorage-compatible keys.
/// Complex configurations are stored as JSON in ~/Library/Application Support/FreeAudio/.
@MainActor
final class SettingsService: ObservableObject, @unchecked Sendable {
    static let shared = SettingsService()

    private let defaults = UserDefaults.standard
    private let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("FreeAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        loadAll()
        loadAppSettings()
        loadDeviceSettings()
    }

    // MARK: - Keys

    private enum Keys {
        static let launchAtLogin          = "fa.launchAtLogin"
        static let launchAtLoginPrompted  = "fa.launchAtLogin.prompted"
        static let checkUpdatesOnLaunch   = "fa.checkUpdatesOnLaunch"
        static let hiddenApps             = "fa.hiddenApps"
        static let migrationVersion       = "fa.migrationVersion"
    }

    // MARK: - Published Settings

    @Published var launchAtLogin: Bool = false {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Whether the first-launch "enable Launch at Login?" prompt has been shown.
    @Published var launchAtLoginPrompted: Bool = false {
        didSet { defaults.set(launchAtLoginPrompted, forKey: Keys.launchAtLoginPrompted) }
    }

    /// App IDs (`AudioApp.id`) hidden from the app list. Purely visual: a hidden app keeps its
    /// saved level, mute and output, and they are still applied.
    @Published private(set) var hiddenApps: Set<String> = [] {
        didSet { defaults.set(hiddenApps.sorted(), forKey: Keys.hiddenApps) }
    }

    func setHidden(_ hidden: Bool, app id: String) {
        if hidden { hiddenApps.insert(id) } else { hiddenApps.remove(id) }
    }

    @Published var checkUpdatesOnLaunch: Bool = true {
        didSet { defaults.set(checkUpdatesOnLaunch, forKey: Keys.checkUpdatesOnLaunch) }
    }

    // MARK: - Per-App Settings

    /// Saved per-app settings keyed by `AudioApp.id`. Apps at default settings have no entry.
    @Published private(set) var appSettings: [String: AppSetting] = [:]

    private static let appSettingsFile = "apps.json"
    private var appSettingsSaveTask: Task<Void, Never>?

    func appSetting(for key: String) -> AppSetting {
        appSettings[key] ?? AppSetting()
    }

    /// Changes one app's settings and schedules a save. Entries back at default are removed.
    func updateAppSetting(_ key: String, name: String?, _ change: (inout AppSetting) -> Void) {
        var setting = appSetting(for: key)
        change(&setting)
        if let name { setting.name = name }
        let newValue: AppSetting? = setting.isDefault ? nil : setting
        guard appSettings[key] != newValue else { return }
        appSettings[key] = newValue
        scheduleAppSettingsSave()
    }

    func resetAppSetting(_ key: String) {
        guard appSettings.removeValue(forKey: key) != nil else { return }
        scheduleAppSettingsSave()
    }

    func resetAllAppSettings() {
        guard !appSettings.isEmpty else { return }
        appSettings = [:]
        scheduleAppSettingsSave()
    }

    private func loadAppSettings() {
        let url = supportDir.appendingPathComponent(Self.appSettingsFile)
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            appSettings = try JSONDecoder().decode(AppSettingsFile.self, from: data).apps.filter { !$0.value.isDefault }
        } catch {
            // Keep the unreadable file for inspection instead of overwriting it on the next save.
            let backup = supportDir.appendingPathComponent("apps.backup.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            settingsLog.error("apps.json unreadable (\(error.localizedDescription, privacy: .public)); moved to apps.backup.json")
        }
    }

    /// Slider drags change settings many times a second; write at most every 500 ms.
    private func scheduleAppSettingsSave() {
        appSettingsSaveTask?.cancel()
        appSettingsSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveAppSettingsNow()
        }
    }

    /// Writes pending app and device settings immediately (on quit).
    func flushPendingSaves() {
        if appSettingsSaveTask != nil {
            appSettingsSaveTask?.cancel()
            saveAppSettingsNow()
        }
        if deviceSettingsSaveTask != nil {
            deviceSettingsSaveTask?.cancel()
            saveDeviceSettingsNow()
        }
    }

    private func saveAppSettingsNow() {
        appSettingsSaveTask = nil
        save(AppSettingsFile(apps: appSettings), filename: Self.appSettingsFile)
    }

    // MARK: - Per-Device Settings

    /// Saved per-device settings keyed by device UID. Devices at default settings have no entry.
    @Published private(set) var deviceSettings: [String: DeviceSetting] = [:]

    private static let deviceSettingsFile = "devices.json"
    private var deviceSettingsSaveTask: Task<Void, Never>?

    func deviceSetting(for uid: String) -> DeviceSetting {
        deviceSettings[uid] ?? DeviceSetting()
    }

    func updateDeviceSetting(_ uid: String, name: String?, _ change: (inout DeviceSetting) -> Void) {
        var setting = deviceSetting(for: uid)
        change(&setting)
        if let name { setting.name = name }
        let newValue: DeviceSetting? = setting.isDefault ? nil : setting
        guard deviceSettings[uid] != newValue else { return }
        deviceSettings[uid] = newValue
        deviceSettingsSaveTask?.cancel()
        deviceSettingsSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveDeviceSettingsNow()
        }
    }

    private func loadDeviceSettings() {
        let url = supportDir.appendingPathComponent(Self.deviceSettingsFile)
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            deviceSettings = try JSONDecoder().decode(DeviceSettingsFile.self, from: data).devices.filter { !$0.value.isDefault }
        } catch {
            let backup = supportDir.appendingPathComponent("devices.backup.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            settingsLog.error("devices.json unreadable (\(error.localizedDescription, privacy: .public)); moved to devices.backup.json")
        }
    }

    private func saveDeviceSettingsNow() {
        deviceSettingsSaveTask = nil
        save(DeviceSettingsFile(devices: deviceSettings), filename: Self.deviceSettingsFile)
    }

    // MARK: - JSON Persistence Helpers

    func save<T: Encodable>(_ value: T, filename: String) {
        let url = supportDir.appendingPathComponent(filename)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            settingsLog.error("Saving \(filename, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        let url = supportDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Load All

    private func loadAll() {
        // Sync launch-at-login from the authoritative launchd agent state, not just UserDefaults.
        // This handles the case where the user toggled it externally or after a fresh install.
        launchAtLogin = LaunchService.shared.isEnabled
        launchAtLoginPrompted = defaults.bool(forKey: Keys.launchAtLoginPrompted)
        hiddenApps = Set(defaults.stringArray(forKey: Keys.hiddenApps) ?? [])
        checkUpdatesOnLaunch = defaults.object(forKey: Keys.checkUpdatesOnLaunch) != nil
            ? defaults.bool(forKey: Keys.checkUpdatesOnLaunch) : true
    }

    // MARK: - Migration

    /// One-time cleanup of keys from older versions. Call before any service reads defaults.
    /// Bump `currentMigrationVersion` and add a step when a key is renamed or dropped.
    static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        let currentMigrationVersion = 1
        guard defaults.integer(forKey: Keys.migrationVersion) < currentMigrationVersion else { return }
        defaults.set(currentMigrationVersion, forKey: Keys.migrationVersion)
    }
}

// MARK: - App Language

/// UI languages the app can switch between at runtime (Settings → Dil / Language).
enum AppLanguage: String, CaseIterable, Sendable {
    case tr, en
}

/// Holds the in-app UI language, persisted under `fa.language` (default: Turkish).
/// Hand-written `Observable` conformance (no macro needed): any view body that calls
/// `L(_:_:)` reads `language` and therefore re-renders immediately when it changes.
final class LanguageStore: Observable, @unchecked Sendable {
    static let shared = LanguageStore()

    private static let key = "fa.language"
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var storedLanguage: AppLanguage

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? ""
        storedLanguage = AppLanguage(rawValue: saved) ?? .tr
    }

    var language: AppLanguage {
        get {
            registrar.access(self, keyPath: \.language)
            return lock.withLock { storedLanguage }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.language) {
                lock.withLock { storedLanguage = newValue }
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.key)
        }
    }
}

/// Returns the UI string for the current in-app language: `L("Ayarlar", "Settings")`.
func L(_ tr: String, _ en: String) -> String {
    LanguageStore.shared.language == .en ? en : tr
}

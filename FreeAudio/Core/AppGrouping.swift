import Foundation

/// One Core Audio process object as `AppAudioService` read it.
struct ProcessRecord: Sendable, Equatable {
    let objectID: UInt32
    let pid: Int32
    /// Core Audio's bundle ID for the process; nil (or empty) for plain executables.
    let bundleID: String?
    let isRunningOutput: Bool
    let executablePath: String?
    /// The process macOS holds responsible for this one (private responsibility API).
    let responsiblePID: Int32?
    let outputDeviceUIDs: [String]
}

/// A running application as AppKit describes it.
struct AppInfo: Sendable, Equatable {
    let bundleID: String
    let name: String
    let pid: Int32?
    /// Path of the `.app` bundle.
    let bundlePath: String?
}

/// An app and all of its audio processes (helpers, XPC services), shown as one row.
struct AudioApp: Sendable, Equatable, Identifiable {
    /// Settings key: the app's bundle ID, or `exec:<name>` for a process without a bundle.
    let id: String
    var name: String
    var bundleID: String?
    var appPID: Int32?
    var bundlePath: String?
    var processObjectIDs: [UInt32] = []
    var pids: [Int32] = []
    /// Bundle IDs of member processes other than the app itself (e.g. its helpers).
    var helperBundleIDs: [String] = []
    var isPlaying = false
    var outputDeviceUIDs: [String] = []
}

/// Groups Core Audio processes into apps. Pure: AppKit lookups are passed in.
enum AppGrouping {
    /// System processes that never get a row: alerts and system audio daemons are covered by the
    /// device volume, and tapping speech/dictation processes silences their chimes.
    static let excludedBundleIDs: Set<String> = [
        "systemsoundserverd", "com.apple.audiomxd", "com.apple.coreaudiod", "com.apple.PowerChime",
        "com.apple.CoreSpeech", "com.apple.assistantd", "com.apple.accessibility.heard",
        "com.apple.SpeechRecognitionCore.speechrecognitiond", "com.apple.mediaremoted",
    ]
    static let excludedBundleIDPrefixes = ["com.apple.siri", "com.apple.dictation", "com.apple.speech"]
    static let excludedExecutables: Set<String> = ["coreaudiod", "systemsoundserverd", "audiomxd", "corespeechd"]

    static func isExcluded(_ record: ProcessRecord) -> Bool {
        if let bundleID = record.bundleID, !bundleID.isEmpty {
            if excludedBundleIDs.contains(bundleID) { return true }
            if excludedBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        }
        if let name = record.executablePath.map({ ($0 as NSString).lastPathComponent }), excludedExecutables.contains(name) {
            return true
        }
        return false
    }

    /// The outermost `.app` bundle containing `path`, e.g. "/Applications/Google Chrome.app" for
    /// a Chrome helper's executable. nil when the path isn't inside an app bundle.
    static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Which app a process belongs to:
    /// 1. the process itself, if it is a top-level `.app` (not a helper bundle nested in one);
    /// 2. for bundled processes, the app macOS holds responsible (WebKit XPC → Safari/Outlook);
    /// 3. the outermost `.app` its executable lives in (Chrome and Electron helpers);
    /// 4. otherwise its own row. Plain executables (afplay, CLI tools) are not attributed to the
    ///    terminal that launched them, which is what responsibility would say.
    static func owner(
        of record: ProcessRecord,
        appForPID: (Int32) -> AppInfo?,
        appForBundlePath: (String) -> AppInfo?
    ) -> AppInfo? {
        if let own = appForPID(record.pid), let path = own.bundlePath, outermostAppBundle(in: path) == path {
            return own
        }
        let isBundled = !(record.bundleID ?? "").isEmpty
        if isBundled, let responsible = record.responsiblePID, responsible != record.pid,
           let app = appForPID(responsible) {
            return app
        }
        if let executable = record.executablePath, let outer = outermostAppBundle(in: executable),
           let app = appForBundlePath(outer) {
            return app
        }
        return nil
    }

    static func group(
        _ records: [ProcessRecord],
        ownPID: Int32,
        appForPID: (Int32) -> AppInfo?,
        appForBundlePath: (String) -> AppInfo?
    ) -> [AudioApp] {
        var apps: [String: AudioApp] = [:]
        for record in records where record.pid != ownPID && !isExcluded(record) {
            let bundleID = (record.bundleID ?? "").isEmpty ? nil : record.bundleID
            var app: AudioApp
            if let owner = owner(of: record, appForPID: appForPID, appForBundlePath: appForBundlePath) {
                app = apps[owner.bundleID] ?? AudioApp(
                    id: owner.bundleID, name: owner.name, bundleID: owner.bundleID,
                    appPID: owner.pid, bundlePath: owner.bundlePath)
                if let bundleID, bundleID != owner.bundleID, !app.helperBundleIDs.contains(bundleID) {
                    app.helperBundleIDs.append(bundleID)
                }
            } else {
                let executable = record.executablePath.map { ($0 as NSString).lastPathComponent }
                let key = bundleID ?? "exec:\(executable ?? "pid \(record.pid)")"
                let name = executable ?? bundleID?.split(separator: ".").last.map(String.init) ?? "pid \(record.pid)"
                app = apps[key] ?? AudioApp(id: key, name: name, bundleID: bundleID)
            }
            app.processObjectIDs.append(record.objectID)
            app.pids.append(record.pid)
            app.isPlaying = app.isPlaying || record.isRunningOutput
            for uid in record.outputDeviceUIDs where !app.outputDeviceUIDs.contains(uid) {
                app.outputDeviceUIDs.append(uid)
            }
            apps[app.id] = app
        }
        return apps.values.map { app in
            var app = app
            app.processObjectIDs.sort()
            app.pids.sort()
            app.helperBundleIDs.sort()
            app.outputDeviceUIDs.sort()
            return app
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

import Foundation

/// What one tap engine should look like: a tap + private aggregate + IOProc that plays the app at
/// `gain` (0 when muted). `TapService` computes the desired set from apps, settings and
/// permission; `EngineDiff` turns the difference into actions.
struct EngineSpec: Equatable, Sendable {
    /// The app's settings key (`AudioApp.id`).
    let key: String
    /// Output device the aggregate plays to.
    var deviceUID: String
    /// Process objects in the tap (helpers whose bundle IDs other apps share are only here).
    var processObjectIDs: [UInt32]
    /// Bundle IDs the tap follows across relaunches (macOS 26 `bundleIDs`, spike S5).
    var bundleIDs: [String]
    var gain: Float
}

enum EngineAction: Equatable, Sendable {
    case create(EngineSpec)
    /// Output device changed: build the new engine, then remove the old one.
    case replace(EngineSpec)
    /// Same device, different processes or followed bundle IDs: update the tap description in
    /// place (spike S4), no rebuild.
    case updateTap(key: String, processObjectIDs: [UInt32], bundleIDs: [String])
    /// Gain only: written to the engine's real-time state, no HAL work.
    case setGain(key: String, gain: Float)
    case destroy(key: String)
}

enum EngineDiff {
    static let gainTolerance: Float = 0.0001

    static func actions(current: [String: EngineSpec], desired: [String: EngineSpec]) -> [EngineAction] {
        var actions: [EngineAction] = []
        for key in current.keys.sorted() where desired[key] == nil {
            actions.append(.destroy(key: key))
        }
        for key in desired.keys.sorted() {
            guard let want = desired[key] else { continue }
            guard let have = current[key] else {
                actions.append(.create(want))
                continue
            }
            if want.deviceUID != have.deviceUID {
                actions.append(.replace(want))
                continue
            }
            if Set(want.processObjectIDs) != Set(have.processObjectIDs) || Set(want.bundleIDs) != Set(have.bundleIDs) {
                actions.append(.updateTap(key: key, processObjectIDs: want.processObjectIDs, bundleIDs: want.bundleIDs))
            }
            if abs(want.gain - have.gain) > gainTolerance {
                actions.append(.setGain(key: key, gain: want.gain))
            }
        }
        return actions
    }

    /// The device an app's engine plays to: the real output device the app uses, else the default.
    /// Right after the default output changes, an app still reported on the previous default is
    /// treated as following the default: macOS moves it, but its Devices property can lag.
    static func outputDevice(
        appDeviceUIDs: [String],
        outputUIDs: Set<String>,
        defaultUID: String,
        previousDefaultUID: String?,
        defaultChangedRecently: Bool
    ) -> String {
        guard let own = appDeviceUIDs.first(where: outputUIDs.contains) else { return defaultUID }
        if defaultChangedRecently, own == previousDefaultUID { return defaultUID }
        return own
    }

    /// Bundle IDs a tap may follow for an app: its own, plus helper IDs under its own prefix
    /// (e.g. `com.google.Chrome.helper`). Shared helper IDs such as `com.apple.WebKit.GPU` or a
    /// generic Electron helper belong to many apps and are tracked by process object instead.
    static func followedBundleIDs(appBundleID: String?, helperBundleIDs: [String]) -> [String] {
        guard let appBundleID, !appBundleID.isEmpty else { return [] }
        return [appBundleID] + helperBundleIDs.filter { $0.hasPrefix(appBundleID + ".") }.sorted()
    }
}

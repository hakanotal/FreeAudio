import Foundation

/// What one tap engine should look like. `TapService` computes the desired set from apps,
/// settings and permission; `EngineDiff` turns the difference into actions.
struct EngineSpec: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Tap + private aggregate + IOProc that plays the app at `gain`.
        case app
        /// A bare muted tap, no aggregate (spike S6): silences the app at no cost.
        case muteOnly
    }

    /// The app's settings key (`AudioApp.id`).
    let key: String
    var kind: Kind
    /// Output device the aggregate plays to (unused for `muteOnly`).
    var deviceUID: String
    /// Process objects in the tap (helpers whose bundle IDs other apps share are only here).
    var processObjectIDs: [UInt32]
    /// Bundle IDs the tap follows across relaunches (macOS 26 `bundleIDs`, spike S5).
    var bundleIDs: [String]
    var gain: Float
}

enum EngineAction: Equatable, Sendable {
    case create(EngineSpec)
    /// Kind, device or followed bundle IDs changed: build the new engine, then remove the old one.
    case replace(EngineSpec)
    /// Same engine, different processes: update the tap description in place (spike S4).
    case updateProcesses(key: String, processObjectIDs: [UInt32])
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
            let deviceMatters = want.kind == .app
            if want.kind != have.kind || want.bundleIDs != have.bundleIDs || (deviceMatters && want.deviceUID != have.deviceUID) {
                actions.append(.replace(want))
                continue
            }
            if Set(want.processObjectIDs) != Set(have.processObjectIDs) {
                actions.append(.updateProcesses(key: key, processObjectIDs: want.processObjectIDs))
            }
            if want.kind == .app, abs(want.gain - have.gain) > gainTolerance {
                actions.append(.setGain(key: key, gain: want.gain))
            }
        }
        return actions
    }

    /// Bundle IDs a tap may follow for an app: its own, plus helper IDs under its own prefix
    /// (e.g. `com.google.Chrome.helper`). Shared helper IDs such as `com.apple.WebKit.GPU` or a
    /// generic Electron helper belong to many apps and are tracked by process object instead.
    static func followedBundleIDs(appBundleID: String?, helperBundleIDs: [String]) -> [String] {
        guard let appBundleID, !appBundleID.isEmpty else { return [] }
        return [appBundleID] + helperBundleIDs.filter { $0.hasPrefix(appBundleID + ".") }.sorted()
    }
}

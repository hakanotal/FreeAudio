import Foundation

/// What one tap engine should look like: a tap + private aggregate + IOProc that plays its audio
/// at `gain`. `TapService` computes the desired set from apps, devices, settings and permission;
/// `EngineDiff` turns the difference into actions.
struct EngineSpec: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// One controlled app (stereo mixdown of its processes), played at its gain (0 when muted).
        case app
        /// Software volume: everything bound for `deviceUID` except `processObjectIDs` and
        /// `bundleIDs` (FreeAudio and the controlled apps), played at the device gain.
        case rest(stream: UInt)
    }

    /// `AudioApp.id` for app engines, `SoftwareVolumePlan.restKey` for rest engines.
    let key: String
    var kind: Kind = .app
    /// Output device the aggregate plays to.
    var deviceUID: String
    /// App engines: processes in the tap (helpers whose bundle IDs other apps share are only
    /// here). Rest engines: processes excluded.
    var processObjectIDs: [UInt32]
    /// App engines: bundle IDs followed across relaunches (spike S5). Rest engines: excluded.
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
            if want.deviceUID != have.deviceUID || want.kind != have.kind {
                actions.append(.replace(want))
                continue
            }
            // A rest engine's exclusions change when apps become controlled or go back to
            // default; the new rest engine crosses over with the old one and the app engines.
            if case .rest = want.kind,
               Set(want.processObjectIDs) != Set(have.processObjectIDs) || Set(want.bundleIDs) != Set(have.bundleIDs) {
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

import Foundation

/// The engine set one reconcile pass wants, computed from apps, settings and devices. Pure:
/// `TapService` gathers the input, handles the side effects (permission, timers, saving helper
/// IDs) and turns the difference into HAL work with `EngineDiff`.
enum EnginePlan {
    struct Input: Sendable {
        /// Every grouped audio client, playing or not.
        var apps: [AudioApp] = []
        var appSettings: [String: AppSetting] = [:]
        var deviceSettings: [String: DeviceSetting] = [:]
        /// Listed output devices, and the ones whose level is set in software.
        var outputUIDs: Set<String> = []
        var softwareOutputUIDs: Set<String> = []
        var defaultUID: String?
        var previousDefaultUID: String?
        var defaultChangedRecently = false
        /// The engines that exist now.
        var current: [String: EngineSpec] = [:]
        /// Keys whose engine failed recently: no engine until their backoff ends.
        var backedOff: Set<String> = []
        /// Devices whose rest engine failed recently. A device that still has its old rest engine
        /// keeps its whole engine set as it is (gains still follow), so nothing it excludes ends
        /// up unprocessed; a device without one just gets no rest engine for now.
        var restBackedOff: Set<String> = []
        /// Global index of the default output's first output stream (for the rest tap); nil
        /// when the device has none or doesn't use software volume.
        var restStream: UInt?
        /// The default output's software volume returned to 100% moments ago: keep its rest
        /// engine a little longer, so dragging through 100% doesn't rebuild it.
        var holdRestAtUnity = false
        var ownProcessObjectIDs: [UInt32] = []
        var ownBundleID = "com.freeaudio.app"
    }

    struct Result: Equatable, Sendable {
        var specs: [String: EngineSpec] = [:]
        /// Helper bundle IDs to remember per app (already merged with the saved ones), so a tap
        /// prepared before the app starts covers them.
        var helpersToSave: [String: [String]] = [:]
    }

    /// Muting is gain 0 on the regular engine: a gain change fades in 30 ms with no HAL work.
    static func gain(for setting: AppSetting) -> Float {
        setting.muted ? 0 : setting.gain
    }

    /// The default output uses software volume, is back at 100%, and still has a rest engine.
    static func restIsAtUnity(_ input: Input) -> Bool {
        guard let uid = input.defaultUID, input.softwareOutputUIDs.contains(uid) else { return false }
        return (input.deviceSettings[uid] ?? DeviceSetting()).isUnity
            && input.current[SoftwareVolumePlan.restKey(deviceUID: uid)] != nil
    }

    static func desired(_ input: Input) -> Result {
        var result = Result()
        // Without an output nothing can be built. Keep what runs: a device list read in the
        // middle of a burst can come back empty for a moment, and tearing every engine down
        // would play muted apps at full volume.
        guard let defaultUID = input.defaultUID, !defaultUID.isEmpty else {
            result.specs = input.current
            return result
        }

        var specs: [String: EngineSpec] = [:]
        for app in input.apps where !input.backedOff.contains(app.id) {
            let setting = input.appSettings[app.id] ?? AppSetting()
            let device = EngineDiff.outputDevice(
                routedUID: setting.outputDeviceUID, appDeviceUIDs: app.outputDeviceUIDs,
                outputUIDs: input.outputUIDs, defaultUID: defaultUID,
                previousDefaultUID: input.previousDefaultUID, defaultChangedRecently: input.defaultChangedRecently)
            if setting.isDefault {
                // Back at default: keep a running engine at unity while the app plays on the
                // same device, so dragging through 100% doesn't tear the tap down. Once the app
                // is quiet, or its audio belongs on another device (routing reset, default
                // switch, device gone), the engine goes and the app plays untouched.
                if var existing = input.current[app.id], existing.kind == .app, app.isPlaying, existing.deviceUID == device {
                    existing.gain = 1
                    existing.processObjectIDs = app.processObjectIDs
                    specs[app.id] = existing
                }
                continue
            }
            let saved = setting.helpers ?? []
            let helpers = EngineDiff.followedBundleIDs(appBundleID: app.bundleID, helperBundleIDs: app.helperBundleIDs)
                .filter { $0 != app.bundleID }
            if !Set(helpers).isSubset(of: Set(saved)) {
                result.helpersToSave[app.id] = Array(Set(helpers).union(saved)).sorted()
            }
            specs[app.id] = EngineSpec(
                key: app.id,
                deviceUID: device,
                processObjectIDs: app.processObjectIDs,
                bundleIDs: EngineDiff.followedBundleIDs(appBundleID: app.bundleID, helperBundleIDs: app.helperBundleIDs + saved),
                gain: gain(for: setting))
        }

        // Saved apps that aren't running get a pre-armed tap that follows their bundle ID, so
        // they're controlled from their first sound (spike S5: an empty tap costs nothing and
        // picks the app up when it starts). No process objects: Core Audio reuses object IDs,
        // and a tap must never pick up an unrelated process. Plain executables (`exec:`) have
        // no bundle ID to follow.
        let present = Set(input.apps.map(\.id))
        for (key, setting) in input.appSettings
        where !present.contains(key) && !key.hasPrefix("exec:") && !setting.isDefault && !input.backedOff.contains(key) {
            specs[key] = EngineSpec(
                key: key,
                deviceUID: setting.outputDeviceUID.flatMap { input.outputUIDs.contains($0) ? $0 : nil } ?? defaultUID,
                processObjectIDs: [],
                bundleIDs: EngineDiff.followedBundleIDs(appBundleID: key, helperBundleIDs: setting.helpers ?? []),
                gain: gain(for: setting))
        }

        // Software volume on the default output: a rest engine for everything that isn't a
        // controlled app, and the device gain on the app engines there.
        let defaultSetting = input.deviceSettings[defaultUID] ?? DeviceSetting()
        if input.softwareOutputUIDs.contains(defaultUID), let stream = input.restStream,
           !defaultSetting.isUnity || input.holdRestAtUnity {
            SoftwareVolumePlan.applyDeviceGain(&specs, deviceUID: defaultUID, deviceGain: defaultSetting.gain)
            if !input.restBackedOff.contains(defaultUID) || input.current[SoftwareVolumePlan.restKey(deviceUID: defaultUID)] != nil {
                specs[SoftwareVolumePlan.restKey(deviceUID: defaultUID)] = SoftwareVolumePlan.restSpec(
                    deviceUID: defaultUID, stream: stream, deviceGain: defaultSetting.gain,
                    appSpecs: Array(specs.values), ownProcessObjectIDs: input.ownProcessObjectIDs,
                    ownBundleID: input.ownBundleID)
            }
        }
        // Apps routed to another software-volume device (e.g. an HDMI monitor that isn't the
        // default) carry that device's level too. Only the default output gets a rest engine.
        for uid in input.softwareOutputUIDs where uid != defaultUID {
            let setting = input.deviceSettings[uid] ?? DeviceSetting()
            guard !setting.isUnity else { continue }
            SoftwareVolumePlan.applyDeviceGain(&specs, deviceUID: uid, deviceGain: setting.gain)
        }

        for device in input.restBackedOff where input.current[SoftwareVolumePlan.restKey(deviceUID: device)] != nil {
            freeze(device, in: &specs, input: input)
        }
        result.specs = specs
        return result
    }

    /// Keeps `device`'s current engines exactly as they are apart from their gains, and starts
    /// nothing new there: its rest engine excludes precisely those engines' processes.
    private static func freeze(_ device: String, in specs: inout [String: EngineSpec], input: Input) {
        let setting = input.deviceSettings[device] ?? DeviceSetting()
        let deviceGain = input.softwareOutputUIDs.contains(device) ? setting.gain : 1
        let keys = Set(input.current.filter { $0.value.deviceUID == device }.keys)
            .union(specs.filter { $0.value.deviceUID == device }.keys)
        for key in keys {
            guard var kept = input.current[key] else {
                specs.removeValue(forKey: key)
                continue
            }
            guard kept.deviceUID == device else {
                // Wants to move onto the frozen device: stays where it is for now.
                specs[key] = kept
                continue
            }
            if let wanted = specs[key], wanted.deviceUID == device, wanted.kind == kept.kind {
                kept.gain = wanted.gain
            } else {
                // An app back at default (unity), or a rest engine no longer wanted.
                kept.gain = deviceGain
            }
            specs[key] = kept
        }
    }
}

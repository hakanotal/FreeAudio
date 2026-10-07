import Testing
@testable import FreeAudioCore

/// The reconciler's desired engine set (what `TapService` asks for each pass).
struct EnginePlanTests {
    static func app(_ id: String, processes: [UInt32] = [10], devices: [String] = ["speakers"], playing: Bool = true,
                    helpers: [String] = []) -> AudioApp {
        AudioApp(id: id, name: id, bundleID: id.hasPrefix("exec:") ? nil : id, processObjectIDs: processes,
                 helperBundleIDs: helpers, isPlaying: playing, outputDeviceUIDs: devices)
    }

    static func input(apps: [AudioApp] = [], settings: [String: AppSetting] = [:], current: [String: EngineSpec] = [:],
                      defaultUID: String? = "speakers") -> EnginePlan.Input {
        var input = EnginePlan.Input()
        input.apps = apps
        input.appSettings = settings
        input.outputUIDs = ["speakers", "airpods", "dell"]
        input.defaultUID = defaultUID
        input.current = current
        input.ownProcessObjectIDs = [5]
        return input
    }

    /// Input with the Dell as a software-volume default output at `level`.
    static func dellInput(apps: [AudioApp], settings: [String: AppSetting] = [:], level: Double = 0.5,
                          current: [String: EngineSpec] = [:]) -> EnginePlan.Input {
        var input = input(apps: apps, settings: settings, current: current, defaultUID: "dell")
        input.softwareOutputUIDs = ["dell"]
        input.deviceSettings = ["dell": DeviceSetting(softwareVolume: level)]
        input.restStream = 0
        return input
    }

    @Test func appAtDefaultIsLeftAlone() {
        let result = EnginePlan.desired(Self.input(apps: [Self.app("spotify")]))
        #expect(result.specs.isEmpty)
    }

    @Test func controlledAppGetsAnEngineOnItsDevice() {
        let result = EnginePlan.desired(Self.input(apps: [Self.app("spotify", devices: ["airpods"])],
                                                   settings: ["spotify": AppSetting(level: 50)]))
        let spec = result.specs["spotify"]
        #expect(spec?.deviceUID == "airpods")
        #expect(spec?.processObjectIDs == [10])
        #expect(spec?.bundleIDs == ["spotify"])
        #expect(spec?.gain == Float(VolumeCurve.appGain(forPercent: 50)))
        #expect(EnginePlan.desired(Self.input(apps: [Self.app("spotify")], settings: ["spotify": AppSetting(muted: true)])).specs["spotify"]?.gain == 0)
    }

    @Test func keptEngineStaysAtUnityWhileItsAppPlaysOnTheSameDevice() {
        let running = EngineSpec(key: "spotify", deviceUID: "speakers", processObjectIDs: [10], bundleIDs: ["spotify"], gain: 0.3)
        let result = EnginePlan.desired(Self.input(apps: [Self.app("spotify", processes: [10, 11])], current: ["spotify": running]))
        #expect(result.specs["spotify"]?.gain == 1)
        #expect(result.specs["spotify"]?.processObjectIDs == [10, 11])
    }

    @Test func keptEngineIsDroppedWhenTheAppBelongsOnAnotherDevice() {
        // Routed to the AirPods, then set back to "System default" at 100% while playing: the app's
        // own audio goes to the speakers, so the AirPods engine must go.
        let routed = EngineSpec(key: "spotify", deviceUID: "airpods", processObjectIDs: [10], bundleIDs: ["spotify"], gain: 1)
        let result = EnginePlan.desired(Self.input(apps: [Self.app("spotify", devices: ["speakers"])], current: ["spotify": routed]))
        #expect(result.specs["spotify"] == nil)
    }

    @Test func keptEngineIsDroppedWhenTheAppGoesQuiet() {
        let running = EngineSpec(key: "spotify", deviceUID: "speakers", processObjectIDs: [10], bundleIDs: ["spotify"], gain: 1)
        let result = EnginePlan.desired(Self.input(apps: [Self.app("spotify", playing: false)], current: ["spotify": running]))
        #expect(result.specs.isEmpty)
    }

    @Test func savedAppThatIsNotRunningGetsAPreArmedTap() {
        let settings = ["com.spotify.client": AppSetting(level: 40, helpers: ["com.spotify.client.helper"]),
                        "exec:afplay": AppSetting(level: 40)]
        let result = EnginePlan.desired(Self.input(settings: settings))
        let spec = result.specs["com.spotify.client"]
        #expect(spec?.processObjectIDs == [])
        #expect(spec?.bundleIDs == ["com.spotify.client", "com.spotify.client.helper"])
        #expect(spec?.deviceUID == "speakers")
        // A plain executable has no bundle ID to follow.
        #expect(result.specs["exec:afplay"] == nil)
    }

    @Test func routedAppFallsBackToTheDefaultWhileItsDeviceIsMissing() {
        let routed = AppSetting(outputDeviceUID: "usb-dac")
        #expect(EnginePlan.desired(Self.input(apps: [Self.app("music")], settings: ["music": routed])).specs["music"]?.deviceUID == "speakers")
        #expect(EnginePlan.desired(Self.input(settings: ["music": routed])).specs["music"]?.deviceUID == "speakers")
        let connected = AppSetting(outputDeviceUID: "airpods")
        #expect(EnginePlan.desired(Self.input(apps: [Self.app("music")], settings: ["music": connected])).specs["music"]?.deviceUID == "airpods")
    }

    @Test func newHelpersAreReportedForSaving() {
        let result = EnginePlan.desired(Self.input(
            apps: [Self.app("com.google.Chrome", helpers: ["com.google.Chrome.helper", "com.apple.WebKit.GPU"])],
            settings: ["com.google.Chrome": AppSetting(level: 50, helpers: ["com.google.Chrome.old"])]))
        #expect(result.helpersToSave["com.google.Chrome"] == ["com.google.Chrome.helper", "com.google.Chrome.old"])
        #expect(result.specs["com.google.Chrome"]?.bundleIDs == ["com.google.Chrome", "com.google.Chrome.helper", "com.google.Chrome.old"])
        // Nothing new: nothing to save.
        let known = EnginePlan.desired(Self.input(
            apps: [Self.app("com.google.Chrome", helpers: ["com.google.Chrome.helper"])],
            settings: ["com.google.Chrome": AppSetting(level: 50, helpers: ["com.google.Chrome.helper"])]))
        #expect(known.helpersToSave.isEmpty)
    }

    @Test func backedOffKeysGetNoEngine() {
        var input = Self.input(apps: [Self.app("spotify")], settings: ["spotify": AppSetting(level: 50), "com.saved": AppSetting(level: 50)])
        input.backedOff = ["spotify", "com.saved"]
        #expect(EnginePlan.desired(input).specs.isEmpty)
    }

    @Test func noDefaultOutputKeepsTheCurrentEngines() {
        let running = EngineSpec(key: "spotify", deviceUID: "speakers", processObjectIDs: [10], bundleIDs: ["spotify"], gain: 0)
        for missing in [nil, ""] as [String?] {
            let result = EnginePlan.desired(Self.input(apps: [Self.app("spotify")], settings: ["spotify": AppSetting(muted: true)],
                                                       current: ["spotify": running], defaultUID: missing))
            #expect(result.specs == ["spotify": running])
        }
    }

    @Test func softwareDefaultBelowUnityGetsARestEngineAndDeviceGain() {
        let input = Self.dellInput(apps: [Self.app("zen", devices: ["dell"])], settings: ["zen": AppSetting(level: 100, muted: false, outputDeviceUID: nil)])
        // zen is at default: only the rest engine.
        let plain = EnginePlan.desired(input)
        #expect(plain.specs.keys.sorted() == ["rest:dell"])
        #expect(plain.specs["rest:dell"]?.gain == 0.25)

        let controlled = EnginePlan.desired(Self.dellInput(apps: [Self.app("zen", devices: ["dell"])], settings: ["zen": AppSetting(level: 50)]))
        #expect(controlled.specs["zen"]?.gain == Float(VolumeCurve.appGain(forPercent: 50)) * 0.25)
        // Ownership: the rest engine excludes the controlled app and FreeAudio.
        #expect(controlled.specs["rest:dell"]?.processObjectIDs == [5, 10])
        #expect(controlled.specs["rest:dell"]?.bundleIDs == ["com.freeaudio.app", "zen"])
    }

    @Test func restEngineIsHeldBrieflyAtUnity() {
        let rest = SoftwareVolumePlan.restSpec(deviceUID: "dell", stream: 0, deviceGain: 0.25, appSpecs: [],
                                               ownProcessObjectIDs: [5], ownBundleID: "com.freeaudio.app")
        var input = Self.dellInput(apps: [], level: 1, current: [rest.key: rest])
        #expect(EnginePlan.restIsAtUnity(input))
        #expect(EnginePlan.desired(input).specs.isEmpty)
        input.holdRestAtUnity = true
        #expect(EnginePlan.desired(input).specs[rest.key]?.gain == 1)
        // A hardware default never has a rest engine.
        input.softwareOutputUIDs = []
        #expect(!EnginePlan.restIsAtUnity(input))
        #expect(EnginePlan.desired(input).specs.isEmpty)
    }

    @Test func appsRoutedToAnotherSoftwareDeviceCarryItsGain() {
        var input = Self.input(apps: [Self.app("music")], settings: ["music": AppSetting(outputDeviceUID: "dell")])
        input.softwareOutputUIDs = ["dell"]
        input.deviceSettings = ["dell": DeviceSetting(softwareVolume: 0.5)]
        let result = EnginePlan.desired(input)
        #expect(result.specs["music"]?.gain == 0.25)
        // Only the default output gets a rest engine.
        #expect(result.specs["rest:dell"] == nil)
    }

    @Test func backedOffRestDeviceKeepsItsEngineSet() {
        // Running: the rest engine and zen's engine on the Dell. The rest replacement failed, so
        // the Dell is frozen: spotify, newly controlled, gets no engine (its audio stays inside the
        // old rest engine), zen keeps its engine and follows its new level, and the rest engine
        // keeps excluding exactly what it excluded.
        let zenRunning = EngineSpec(key: "zen", deviceUID: "dell", processObjectIDs: [10], bundleIDs: ["zen"], gain: 0.1)
        let rest = SoftwareVolumePlan.restSpec(deviceUID: "dell", stream: 0, deviceGain: 0.25, appSpecs: [zenRunning],
                                               ownProcessObjectIDs: [5], ownBundleID: "com.freeaudio.app")
        var input = Self.dellInput(apps: [Self.app("zen", devices: ["dell"]), Self.app("spotify", processes: [20], devices: ["dell"])],
                                   settings: ["zen": AppSetting(level: 50), "spotify": AppSetting(level: 30)],
                                   current: ["zen": zenRunning, rest.key: rest])
        input.restBackedOff = ["dell"]
        let result = EnginePlan.desired(input)
        #expect(result.specs["spotify"] == nil)
        #expect(result.specs["zen"]?.gain == Float(VolumeCurve.appGain(forPercent: 50)) * 0.25)
        #expect(result.specs[rest.key] == rest)
        #expect(EngineDiff.actions(current: input.current, desired: result.specs) == [.setGain(key: "zen", gain: Float(VolumeCurve.appGain(forPercent: 50)) * 0.25)])

        // Without a running rest engine there is nothing to protect: no rest engine for now, and
        // app engines are built as usual.
        var fresh = Self.dellInput(apps: [Self.app("zen", devices: ["dell"])], settings: ["zen": AppSetting(level: 50)])
        fresh.restBackedOff = ["dell"]
        let freshResult = EnginePlan.desired(fresh)
        #expect(freshResult.specs["rest:dell"] == nil)
        #expect(freshResult.specs["zen"] != nil)
    }

    @Test func softwareVolumeRule() {
        #expect(DeviceSetting().usesSoftwareVolume(hasHardwareVolume: false))
        #expect(!DeviceSetting().usesSoftwareVolume(hasHardwareVolume: true))
        #expect(DeviceSetting(forceSoftware: true).usesSoftwareVolume(hasHardwareVolume: true))
    }
}

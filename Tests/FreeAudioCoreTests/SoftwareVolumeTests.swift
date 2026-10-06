import Foundation
import Testing
@testable import FreeAudioCore

struct SoftwareVolumeTests {
    private func app(_ key: String, device: String = "dell", processes: [UInt32], bundleIDs: [String] = [], gain: Float = 0.5) -> EngineSpec {
        EngineSpec(key: key, deviceUID: device, processObjectIDs: processes, bundleIDs: bundleIDs, gain: gain)
    }

    @Test func deviceSettingGain() {
        #expect(DeviceSetting().isUnity)
        #expect(DeviceSetting(softwareVolume: 0.5).gain == 0.25)
        #expect(DeviceSetting(softwareVolume: 0.8, softwareMuted: true).gain == 0)
        #expect(!DeviceSetting(forceSoftware: true).isDefault)
        #expect(DeviceSetting(forceSoftware: true).isUnity)
    }

    @Test func deviceSettingDecodesTolerantly() throws {
        let setting = try JSONDecoder().decode(DeviceSetting.self, from: Data(#"{"softwareVolume": 3, "extra": 1}"#.utf8))
        #expect(setting.softwareVolume == 1)
        #expect(!setting.softwareMuted)
    }

    @Test func restExcludesEveryControlledProcessAndFreeAudio() {
        let apps = [app("zen", processes: [10, 11], bundleIDs: ["app.zen"]),
                    app("spotify", device: "speakers", processes: [20], bundleIDs: ["com.spotify.client"])]
        let rest = SoftwareVolumePlan.restSpec(deviceUID: "dell", stream: 0, deviceGain: 0.4, appSpecs: apps,
                                               ownProcessObjectIDs: [5], ownBundleID: "com.freeaudio.app")
        // Ownership rule: every controlled process is excluded (and FreeAudio itself).
        for spec in apps { #expect(Set(spec.processObjectIDs).isSubset(of: Set(rest.processObjectIDs))) }
        #expect(rest.processObjectIDs.contains(5))
        #expect(rest.bundleIDs == ["app.zen", "com.freeaudio.app", "com.spotify.client"])
        #expect(rest.kind == .rest(stream: 0))
        #expect(rest.gain == 0.4)
        #expect(SoftwareVolumePlan.isRestKey(rest.key))
    }

    @Test func appEnginesOnTheDeviceCarryTheDeviceGain() {
        var specs = ["zen": app("zen", processes: [1], gain: 0.5), "spotify": app("spotify", device: "speakers", processes: [2], gain: 0.5)]
        SoftwareVolumePlan.applyDeviceGain(&specs, deviceUID: "dell", deviceGain: 0.5)
        #expect(specs["zen"]?.gain == 0.25)
        #expect(specs["spotify"]?.gain == 0.5)
    }

    @Test func restExclusionChangeIsAReplace() {
        let old = SoftwareVolumePlan.restSpec(deviceUID: "dell", stream: 0, deviceGain: 0.4, appSpecs: [],
                                              ownProcessObjectIDs: [5], ownBundleID: "f")
        let new = SoftwareVolumePlan.restSpec(deviceUID: "dell", stream: 0, deviceGain: 0.4, appSpecs: [app("zen", processes: [10])],
                                              ownProcessObjectIDs: [5], ownBundleID: "f")
        #expect(EngineDiff.actions(current: [old.key: old], desired: [new.key: new]) == [.replace(new)])
        // A device volume change alone is just a gain change.
        var quieter = old
        quieter.gain = 0.1
        #expect(EngineDiff.actions(current: [old.key: old], desired: [old.key: quieter]) == [.setGain(key: old.key, gain: 0.1)])
    }
}

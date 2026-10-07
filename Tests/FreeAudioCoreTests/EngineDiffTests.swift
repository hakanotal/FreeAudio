import Testing
@testable import FreeAudioCore

struct EngineDiffTests {
    private func spec(_ key: String, device: String = "speakers",
                      processes: [UInt32] = [1], bundleIDs: [String] = [], gain: Float = 0.5) -> EngineSpec {
        EngineSpec(key: key, deviceUID: device, processObjectIDs: processes, bundleIDs: bundleIDs, gain: gain)
    }

    @Test func createAndDestroy() {
        let actions = EngineDiff.actions(current: ["old": spec("old")], desired: ["new": spec("new")])
        #expect(actions == [.destroy(key: "old"), .create(spec("new"))])
    }

    @Test func gainOnlyChangeNeedsNoHALWork() {
        let actions = EngineDiff.actions(current: ["a": spec("a", gain: 0.5)], desired: ["a": spec("a", gain: 0.25)])
        #expect(actions == [.setGain(key: "a", gain: 0.25)])
    }

    @Test func newHelperUpdatesTheTapInPlace() {
        let actions = EngineDiff.actions(current: ["a": spec("a", processes: [1])], desired: ["a": spec("a", processes: [2, 1])])
        #expect(actions == [.updateTap(key: "a", processObjectIDs: [2, 1], bundleIDs: [])])
    }

    @Test func newFollowedBundleIDUpdatesTheTapInPlace() {
        let actions = EngineDiff.actions(current: ["a": spec("a", bundleIDs: ["a"])], desired: ["a": spec("a", bundleIDs: ["a", "a.helper"])])
        #expect(actions == [.updateTap(key: "a", processObjectIDs: [1], bundleIDs: ["a", "a.helper"])])
    }

    @Test func processOrderDoesNotMatter() {
        let actions = EngineDiff.actions(current: ["a": spec("a", processes: [1, 2])], desired: ["a": spec("a", processes: [2, 1])])
        #expect(actions.isEmpty)
    }

    @Test func deviceChangeReplaces() {
        #expect(EngineDiff.actions(current: ["a": spec("a")], desired: ["a": spec("a", device: "dell")]) == [.replace(spec("a", device: "dell"))])
    }

    @Test func outputDeviceFollowsTheDefault() {
        let outputs: Set<String> = ["speakers", "dell", "airpods"]
        // No device reported, or not a real output (e.g. FreeAudio's own aggregate): the default.
        #expect(EngineDiff.outputDevice(appDeviceUIDs: [], outputUIDs: outputs, defaultUID: "dell", previousDefaultUID: nil, defaultChangedRecently: false) == "dell")
        #expect(EngineDiff.outputDevice(appDeviceUIDs: ["com.freeaudio.agg.x"], outputUIDs: outputs, defaultUID: "dell", previousDefaultUID: nil, defaultChangedRecently: false) == "dell")
        // The app's own device.
        #expect(EngineDiff.outputDevice(appDeviceUIDs: ["airpods"], outputUIDs: outputs, defaultUID: "dell", previousDefaultUID: "speakers", defaultChangedRecently: true) == "airpods")
        // Still reported on the old default right after a switch: follows the new default.
        #expect(EngineDiff.outputDevice(appDeviceUIDs: ["speakers"], outputUIDs: outputs, defaultUID: "dell", previousDefaultUID: "speakers", defaultChangedRecently: true) == "dell")
        // A device chosen for the app wins while it's connected; otherwise the usual rules apply.
        #expect(EngineDiff.outputDevice(routedUID: "airpods", appDeviceUIDs: ["speakers"], outputUIDs: outputs, defaultUID: "dell", previousDefaultUID: nil, defaultChangedRecently: false) == "airpods")
        #expect(EngineDiff.outputDevice(routedUID: "gone", appDeviceUIDs: [], outputUIDs: outputs, defaultUID: "dell", previousDefaultUID: nil, defaultChangedRecently: false) == "dell")
        // Long after the switch, trust the app (it chose that device itself).
        #expect(EngineDiff.outputDevice(appDeviceUIDs: ["speakers"], outputUIDs: outputs, defaultUID: "dell", previousDefaultUID: "speakers", defaultChangedRecently: false) == "speakers")
    }

    @Test func muteIsAGainChange() {
        // Muting is gain 0 on the running engine: instant, click-free, no HAL work.
        let actions = EngineDiff.actions(current: ["a": spec("a", gain: 0.5)], desired: ["a": spec("a", gain: 0)])
        #expect(actions == [.setGain(key: "a", gain: 0)])
    }

    @Test func followedBundleIDsSkipSharedHelpers() {
        let ids = EngineDiff.followedBundleIDs(appBundleID: "com.google.Chrome",
                                               helperBundleIDs: ["com.google.Chrome.helper", "com.apple.WebKit.GPU", "com.github.Electron.helper"])
        #expect(ids == ["com.google.Chrome", "com.google.Chrome.helper"])
        #expect(EngineDiff.followedBundleIDs(appBundleID: nil, helperBundleIDs: []).isEmpty)
    }
}

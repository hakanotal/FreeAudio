import Testing
@testable import FreeAudioCore

struct EngineDiffTests {
    private func spec(_ key: String, kind: EngineSpec.Kind = .app, device: String = "speakers",
                      processes: [UInt32] = [1], bundleIDs: [String] = [], gain: Float = 0.5) -> EngineSpec {
        EngineSpec(key: key, kind: kind, deviceUID: device, processObjectIDs: processes, bundleIDs: bundleIDs, gain: gain)
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
        #expect(actions == [.updateProcesses(key: "a", processObjectIDs: [2, 1])])
    }

    @Test func processOrderDoesNotMatter() {
        let actions = EngineDiff.actions(current: ["a": spec("a", processes: [1, 2])], desired: ["a": spec("a", processes: [2, 1])])
        #expect(actions.isEmpty)
    }

    @Test func deviceOrKindChangeReplaces() {
        #expect(EngineDiff.actions(current: ["a": spec("a")], desired: ["a": spec("a", device: "dell")]) == [.replace(spec("a", device: "dell"))])
        #expect(EngineDiff.actions(current: ["a": spec("a")], desired: ["a": spec("a", kind: .muteOnly)]) == [.replace(spec("a", kind: .muteOnly))])
    }

    @Test func muteOnlyIgnoresDeviceAndGain() {
        let actions = EngineDiff.actions(current: ["a": spec("a", kind: .muteOnly, device: "x", gain: 0)],
                                         desired: ["a": spec("a", kind: .muteOnly, device: "y", gain: 1)])
        #expect(actions.isEmpty)
    }

    @Test func followedBundleIDsSkipSharedHelpers() {
        let ids = EngineDiff.followedBundleIDs(appBundleID: "com.google.Chrome",
                                               helperBundleIDs: ["com.google.Chrome.helper", "com.apple.WebKit.GPU", "com.github.Electron.helper"])
        #expect(ids == ["com.google.Chrome", "com.google.Chrome.helper"])
        #expect(EngineDiff.followedBundleIDs(appBundleID: nil, helperBundleIDs: []).isEmpty)
    }
}

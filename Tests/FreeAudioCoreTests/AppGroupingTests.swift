import Testing
@testable import FreeAudioCore

/// Process tables modelled on what TapLab saw on macOS 27 (see docs/LESSONS.md).
struct AppGroupingTests {
    static let apps: [Int32: AppInfo] = [
        100: AppInfo(bundleID: "com.apple.Safari", name: "Safari", pid: 100, bundlePath: "/Applications/Safari.app"),
        200: AppInfo(bundleID: "com.microsoft.Outlook", name: "Microsoft Outlook", pid: 200, bundlePath: "/Applications/Microsoft Outlook.app"),
        300: AppInfo(bundleID: "com.google.Chrome", name: "Google Chrome", pid: 300, bundlePath: "/Applications/Google Chrome.app"),
        400: AppInfo(bundleID: "com.anthropic.claudefordesktop", name: "Claude", pid: 400, bundlePath: "/Applications/Claude.app"),
        // An Electron helper that is a .app bundle itself, nested inside Claude.app.
        401: AppInfo(bundleID: "com.anthropic.claudefordesktop.helper", name: "Claude Helper",
                     pid: 401, bundlePath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app"),
        900: AppInfo(bundleID: "com.microsoft.VSCode", name: "Code", pid: 900, bundlePath: "/Applications/Visual Studio Code.app"),
    ]
    static let bundles = Dictionary(uniqueKeysWithValues: apps.values.compactMap { app in app.bundlePath.map { ($0, app) } })

    static func group(_ records: [ProcessRecord], ownPID: Int32 = 1) -> [AudioApp] {
        AppGrouping.group(records, ownPID: ownPID, appForPID: { apps[$0] }, appForBundlePath: { bundles[$0] })
    }

    static func record(_ object: UInt32, pid: Int32, bundleID: String?, path: String?, responsible: Int32? = nil,
                       playing: Bool = true, devices: [String] = ["BuiltInSpeakerDevice"]) -> ProcessRecord {
        ProcessRecord(objectID: object, pid: pid, bundleID: bundleID, isRunningOutput: playing,
                      executablePath: path, responsiblePID: responsible, outputDeviceUIDs: devices)
    }

    @Test func topLevelAppIsItsOwnRow() {
        let result = Self.group([Self.record(10, pid: 100, bundleID: "com.apple.Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari")])
        #expect(result.map(\.id) == ["com.apple.Safari"])
        #expect(result.first?.name == "Safari")
    }

    @Test func webKitProcessGoesToItsResponsibleApp() {
        let gpu = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        let result = Self.group([
            Self.record(10, pid: 100, bundleID: "com.apple.Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", playing: false),
            Self.record(11, pid: 110, bundleID: "com.apple.WebKit.GPU", path: gpu, responsible: 100),
            Self.record(12, pid: 210, bundleID: "com.apple.WebKit.GPU", path: gpu, responsible: 200),
        ])
        #expect(result.map(\.id) == ["com.microsoft.Outlook", "com.apple.Safari"])
        let safari = result.first { $0.id == "com.apple.Safari" }
        #expect(safari?.processObjectIDs == [10, 11])
        #expect(safari?.isPlaying == true)
        #expect(safari?.helperBundleIDs == ["com.apple.WebKit.GPU"])
    }

    @Test func chromeHelperFoundThroughItsBundlePath() {
        // No responsibility answer: the enclosing .app decides.
        let result = Self.group([
            Self.record(20, pid: 310, bundleID: "com.google.Chrome.helper",
                        path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
        ])
        #expect(result.map(\.id) == ["com.google.Chrome"])
        #expect(result.first?.appPID == 300)
    }

    @Test func nestedHelperAppIsNotItsOwnRow() {
        let result = Self.group([
            Self.record(30, pid: 400, bundleID: "com.anthropic.claudefordesktop", path: "/Applications/Claude.app/Contents/MacOS/Claude", playing: false),
            Self.record(31, pid: 401, bundleID: "com.anthropic.claudefordesktop.helper",
                        path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper", responsible: 400),
        ])
        #expect(result.map(\.id) == ["com.anthropic.claudefordesktop"])
        #expect(result.first?.isPlaying == true)
    }

    @Test func plainExecutableIsNotAttributedToTheTerminal() {
        let result = Self.group([Self.record(40, pid: 500, bundleID: nil, path: "/usr/bin/afplay", responsible: 900)])
        #expect(result.map(\.id) == ["exec:afplay"])
        #expect(result.first?.name == "afplay")
    }

    @Test func systemProcessesAndOwnProcessAreExcluded() {
        let result = Self.group([
            Self.record(50, pid: 600, bundleID: "systemsoundserverd", path: "/usr/sbin/systemsoundserverd"),
            Self.record(51, pid: 601, bundleID: "com.apple.siri.embeddedspeech", path: "/System/Library/x"),
            Self.record(52, pid: 1, bundleID: "com.freeaudio.app", path: "/Applications/FreeAudio.app/Contents/MacOS/FreeAudio"),
            Self.record(53, pid: 2, bundleID: "com.freeaudio.app", path: "/Applications/FreeAudio.app/Contents/MacOS/FreeAudio"),
        ], ownPID: 1)
        #expect(result.isEmpty)
    }

    @Test func outputDevicesAreMergedAndSorted() {
        let result = Self.group([
            Self.record(60, pid: 300, bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", devices: ["B"]),
            Self.record(61, pid: 310, bundleID: "com.google.Chrome.helper", path: "/Applications/Google Chrome.app/Contents/Frameworks/x", responsible: 300, devices: ["A", "B"]),
        ])
        #expect(result.first?.outputDeviceUIDs == ["A", "B"])
        #expect(result.first?.pids == [300, 310])
    }

    @Test func outermostAppBundle() {
        #expect(AppGrouping.outermostAppBundle(in: "/Applications/A.app/Contents/Frameworks/B.app/Contents/MacOS/B") == "/Applications/A.app")
        #expect(AppGrouping.outermostAppBundle(in: "/Applications/A.app") == "/Applications/A.app")
        #expect(AppGrouping.outermostAppBundle(in: "/usr/bin/afplay") == nil)
    }
}

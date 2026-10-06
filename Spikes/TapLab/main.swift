import AppKit
import AudioToolbox
import CoreAudio
import Darwin

// TapLab: throwaway probe app for the roadmap spikes (S1, S2, S6, S8, S9 and TCC preflight).
// Every result is written to the window and to ~/Library/Logs/TapLab/taplab.log.

// MARK: - Private API probes (dlsym)

enum PrivateAPI {
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t

    private nonisolated(unsafe) static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private nonisolated(unsafe) static let service = "kTCCServiceAudioCapture" as CFString

    /// Raw TCCAccessPreflight result (0 = authorized, 1 = denied, other = unknown), nil if missing.
    static func audioCapturePreflight() -> Int32? {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)(service, nil)
    }

    static func requestAudioCapture(_ completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { return false }
        unsafeBitCast(sym, to: RequestFn.self)(service, nil) { granted in completion(granted) }
        return true
    }

    /// PID of the process responsible for `pid` (e.g. Safari for a WebKit XPC process), nil if missing.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let result = unsafeBitCast(sym, to: ResponsibilityFn.self)(pid)
        return result > 0 ? result : nil
    }
}

func executablePath(for pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
}

/// The outermost `.app` bundle in a path, e.g. ".../Google Chrome.app" for a Chrome helper.
func outermostApp(in path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return String(path[..<range.lowerBound]) + ".app"
}

// MARK: - OSDUIHelper (same private XPC FreeAudio's VolumeHUDService uses)

@objc enum TapLabOSDImage: CLong {
    case volume = 3
    case mute = 4
}

@objc protocol TapLabOSDProtocol {
    func showImage(_ img: TapLabOSDImage, onDisplayID displayID: CGDirectDisplayID, priority: CUnsignedInt,
                   msecUntilFade: CUnsignedInt, filledChiclets: CUnsignedInt, totalChiclets: CUnsignedInt, locked: Bool)
}

// MARK: - App

@MainActor
final class TapLabDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let targetField = NSTextField(string: "com.apple.Music")
    private let devicePopup = NSPopUpButton()
    private let logView = NSTextView()
    private var outputDevices: [AudioHardwareDevice] = []

    private let halQueue = DispatchQueue(label: "com.freeaudio.taplab.hal")
    private var engines: [SpikeEngine] = []
    private var previousCallbacks: [ObjectIdentifier: UInt64] = [:]
    private var statsTimer: Timer?
    private var gain: Float = 0.3
    /// Scenarios that read the peak meters themselves pause the 1 s stats lines.
    fileprivate var statsPaused = false

    private let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TapLab")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("taplab.log")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        refreshDevices()
        log("TapLab started (pid \(getpid())). macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        tccPreflight()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.printStats() }
        }
        // `--auto`: run the read-only probes (no taps, no audio) and quit. Used to collect data
        // without clicking: open -n build/TapLab.app --args --auto
        if CommandLine.arguments.contains("--auto") {
            listProcesses()
            NSApp.terminate(nil)
        }
        // `--scenario <name> [options]`: run one spike unattended and quit (see Scenarios below).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--scenario"), i + 1 < args.count {
            Task { @MainActor in
                await self.runScenario(args[i + 1], args: args)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        let running = engines
        engines = []
        halQueue.sync { running.forEach { $0.stop(log: { print($0) }) } }
    }

    // MARK: UI

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TapLab"
        window.isReleasedWhenClosed = false

        targetField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        devicePopup.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let rows = NSStackView(views: [
            row([NSTextField(labelWithString: "Target bundle ID:"), targetField,
                 NSTextField(labelWithString: "Output:"), devicePopup, button("Refresh", #selector(refreshDevicesAction))]),
            row([button("List processes (S8)", #selector(listProcesses)), button("TCC preflight", #selector(tccPreflightAction)),
                 button("TCC request", #selector(tccRequest)), button("Clear log", #selector(clearLog))]),
            row([button("S1 app tap → output", #selector(startS1)), button("S2 rest tap on output", #selector(startS2)),
                 button("S6 muted tap only", #selector(startS6)), button("Stop all", #selector(stopAll))]),
            row([button("Gain 0.1", #selector(gain01)), button("Gain 0.3", #selector(gain03)), button("Gain 1.0", #selector(gain10)),
                 button("S9 OSD 50%", #selector(osdHalf)), button("S9 mute OSD", #selector(osdMute))]),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true

        let content = NSStackView(views: [rows, scroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
        let line = "\(stamp) \(message)\n"
        logView.textStorage?.append(NSAttributedString(string: line, attributes: [.font: logView.font!, .foregroundColor: NSColor.labelColor]))
        logView.scrollToEndOfDocument(nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: logURL)
        }
    }

    /// Logger usable from the HAL queue.
    private var halLog: @Sendable (String) -> Void {
        { message in DispatchQueue.main.async { MainActor.assumeIsolated { (NSApp.delegate as? TapLabDelegate)?.log(message) } } }
    }

    @objc private func clearLog() { logView.string = "" }

    // MARK: Devices and processes

    @objc private func refreshDevicesAction() { refreshDevices() }

    private func refreshDevices() {
        let system = AudioHardwareSystem.shared
        let defaultUID = (try? system.defaultOutputDevice?.uid) ?? ""
        outputDevices = ((try? system.devices) ?? []).filter { device in
            ((try? device.streams) ?? []).contains { (try? $0.direction) == .output }
        }
        devicePopup.removeAllItems()
        for device in outputDevices {
            let name = (try? device.name) ?? "?"
            let uid = (try? device.uid) ?? "?"
            let volumeAddress = PropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
            let hasVolume = device.hasProperty(address: volumeAddress) && ((try? device.isPropertySettable(address: volumeAddress)) ?? false)
            devicePopup.addItem(withTitle: "\(name)\(uid == defaultUID ? " (default)" : "")  [\(transportName((try? device.transportType) ?? 0)), \(hasVolume ? "hw volume" : "NO hw volume")]")
        }
        if let index = outputDevices.firstIndex(where: { (try? $0.uid) == defaultUID }) { devicePopup.selectItem(at: index) }
        log("Output devices: \(outputDevices.count); default \(defaultUID)")
    }

    private func transportName(_ t: UInt32) -> String {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        default: String(format: "0x%08x", t)
        }
    }

    private var selectedDevice: AudioHardwareDevice? {
        let i = devicePopup.indexOfSelectedItem
        return i >= 0 && i < outputDevices.count ? outputDevices[i] : nil
    }

    /// Process objects belonging to the target app: same bundle ID, bundle ID prefix (helpers),
    /// responsible process, or an executable inside the app bundle.
    private func targetProcesses() -> [AudioHardwareProcess] {
        let target = targetField.stringValue.trimmingCharacters(in: .whitespaces)
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)?.path
        return ((try? AudioHardwareSystem.shared.processes) ?? []).filter { process in
            guard let pid = try? process.pid, pid != getpid() else { return false }
            let bundleID = (try? process.bundleID) ?? nil
            if let bundleID, bundleID == target || bundleID.hasPrefix(target + ".") { return true }
            if let r = PrivateAPI.responsiblePID(for: pid), r != pid,
               NSRunningApplication(processIdentifier: r)?.bundleIdentifier == target { return true }
            if let appURL, let path = executablePath(for: pid), path.hasPrefix(appURL + "/") { return true }
            return false
        }
    }

    @objc private func listProcesses() {
        let processes = (try? AudioHardwareSystem.shared.processes) ?? []
        log("— \(processes.count) audio process objects —")
        for process in processes {
            let pid = (try? process.pid) ?? -1
            let bundleID = ((try? process.bundleID) ?? nil) ?? "nil"
            let running = (try? process.isRunning) ?? false
            let runningOut = (try? process.isRunningOutput) ?? false
            let runningIn = (try? process.isRunningInput) ?? false
            let devices = ((try? process.devices) ?? []).compactMap { try? $0.name }.joined(separator: ", ")
            let app = NSRunningApplication(processIdentifier: pid)
            let ownApp = app?.bundleURL?.pathExtension == "app" ? app?.bundleIdentifier ?? "?" : "-"
            let responsible = PrivateAPI.responsiblePID(for: pid).flatMap { r in
                r == pid ? nil : "\(r) \(NSRunningApplication(processIdentifier: r)?.bundleIdentifier ?? "?")"
            } ?? "-"
            let path = executablePath(for: pid) ?? "?"
            let enclosing = outermostApp(in: path).map { ($0 as NSString).lastPathComponent } ?? "-"
            log("obj \(process.id) pid \(pid) \(bundleID) run=\(running) out=\(runningOut) in=\(runningIn) | own app: \(ownApp) | responsible: \(responsible) | enclosing .app: \(enclosing) | devices: \(devices)")
        }
        if let own = try? AudioHardwareSystem.shared.process(for: getpid()) {
            log("TapLab's own process object: \(own.id)")
        } else {
            log("TapLab has no process object yet")
        }
    }

    // MARK: TCC

    @objc private func tccPreflightAction() { tccPreflight() }

    private func tccPreflight() {
        if let value = PrivateAPI.audioCapturePreflight() {
            let meaning = value == 0 ? "authorized" : value == 1 ? "denied" : "unknown/not determined"
            log("TCCAccessPreflight(kTCCServiceAudioCapture) = \(value) (\(meaning))")
        } else {
            log("TCCAccessPreflight not available")
        }
    }

    @objc private func tccRequest() {
        let log = halLog
        let started = PrivateAPI.requestAudioCapture { granted in log("TCCAccessRequest callback: granted = \(granted)") }
        log(started ? "TCCAccessRequest sent" : "TCCAccessRequest not available")
    }

    // MARK: Spikes

    private func run(_ engine: SpikeEngine) {
        engines.append(engine)
        previousCallbacks[ObjectIdentifier(engine)] = 0
        let log = halLog
        halQueue.async {
            do {
                try engine.start(log: log)
            } catch {
                log("[\(engine.label)] start failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func startS1() {
        let processes = targetProcesses()
        guard !processes.isEmpty else { log("S1: no audio process for \(targetField.stringValue); start playback first"); return }
        guard let device = selectedDevice, let uid = try? device.uid else { log("S1: no output device"); return }
        log("S1: tapping \(processes.map { "\($0.id)(pid \((try? $0.pid) ?? -1))" }.joined(separator: ", ")) → \((try? device.name) ?? uid), gain \(gain)")
        run(SpikeEngine(label: "S1", kind: .app(processes: processes.map(\.id)), deviceUID: uid, gain: gain))
    }

    @objc private func startS2() {
        guard let device = selectedDevice, let uid = try? device.uid else { log("S2: no output device"); return }
        // Global stream index of the device's first output stream (CATapDescription expects the
        // index in the device's full stream list, not the output-only list).
        let streams = (try? device.streams) ?? []
        guard let streamIndex = streams.firstIndex(where: { (try? $0.direction) == .output }) else { log("S2: device has no output stream"); return }
        var excluded: [AudioObjectID] = []
        if let own = try? AudioHardwareSystem.shared.process(for: getpid()) { excluded.append(own.id) }
        let bundleIDs = [Bundle.main.bundleIdentifier ?? "com.freeaudio.taplab"]
        log("S2: rest tap on \((try? device.name) ?? uid) stream \(streamIndex), excluding objects \(excluded) and bundle IDs \(bundleIDs), gain \(gain)")
        run(SpikeEngine(label: "S2", kind: .rest(excluding: excluded, excludeBundleIDs: bundleIDs, stream: UInt(streamIndex)), deviceUID: uid, gain: gain))
    }

    @objc private func startS6() {
        let processes = targetProcesses()
        guard !processes.isEmpty else { log("S6: no audio process for \(targetField.stringValue); start playback first"); return }
        log("S6: muted tap on \(processes.map(\.id)) with no aggregate")
        run(SpikeEngine(label: "S6", kind: .mutedOnly(processes: processes.map(\.id)), deviceUID: "", gain: 1))
    }

    @objc private func stopAll() {
        let running = engines
        engines = []
        let log = halLog
        halQueue.async { running.forEach { $0.stop(log: log) } }
        log("Stopping \(running.count) engine(s)")
    }

    private func setGain(_ value: Float) {
        gain = value
        engines.forEach { $0.setGain(value) }
        log("Gain → \(value)")
    }

    @objc private func gain01() { setGain(0.1) }
    @objc private func gain03() { setGain(0.3) }
    @objc private func gain10() { setGain(1.0) }

    private func printStats() {
        guard !statsPaused else { return }
        for engine in engines where engine.aggregate != nil {
            var previous = previousCallbacks[ObjectIdentifier(engine)] ?? 0
            log(engine.statsLine(previousCallbacks: &previous))
            previousCallbacks[ObjectIdentifier(engine)] = previous
        }
    }

    // MARK: S9

    fileprivate func showOSD(_ image: TapLabOSDImage, filled: CUnsignedInt) {
        let conn = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: TapLabOSDProtocol.self)
        conn.resume()
        let log = halLog
        let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable error in log("OSD XPC error: \(error.localizedDescription)") }
        guard let helper = proxy as? TapLabOSDProtocol else { log("OSD: no proxy"); conn.invalidate(); return }
        helper.showImage(image, onDisplayID: CGMainDisplayID(), priority: 0x1f4, msecUntilFade: 1500,
                         filledChiclets: filled, totalChiclets: 16, locked: false)
        log("S9: OSD \(image == .mute ? "mute" : "volume \(filled)/16") sent; did it appear?")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { conn.invalidate() }
    }

    @objc private func osdHalf() { showOSD(.volume, filled: 8) }
    @objc private func osdMute() { showOSD(.mute, filled: 0) }
}

// MARK: - Scenarios (unattended spike runs)

extension TapLabDelegate {
    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func startEngine(_ engine: SpikeEngine) async -> Bool {
        engines.append(engine)
        previousCallbacks[ObjectIdentifier(engine)] = 0
        let log = halLog
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            halQueue.async {
                do {
                    try engine.start(log: log)
                    cont.resume(returning: true)
                } catch {
                    log("[\(engine.label)] start failed: \(error.localizedDescription)")
                    cont.resume(returning: false)
                }
            }
        }
    }

    private func stopEngine(_ engine: SpikeEngine) async {
        engines.removeAll { $0 === engine }
        let log = halLog
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            halQueue.async {
                engine.stop(log: log)
                cont.resume()
            }
        }
    }

    /// Preflight; if never asked, request and wait (up to 2 min) for the user to answer the prompt.
    private func ensurePermission() async -> Int32? {
        guard var status = PrivateAPI.audioCapturePreflight() else {
            log("permission: TCCAccessPreflight unavailable")
            return nil
        }
        log("permission: preflight = \(status)")
        if status == 2 {
            tccRequest()
            for _ in 0..<240 {
                await pause(0.5)
                status = PrivateAPI.audioCapturePreflight() ?? status
                if status != 2 { break }
            }
            log("permission: preflight after request = \(status)")
        }
        return status
    }

    private func firstOutputStreamIndex(_ device: AudioHardwareDevice) -> UInt? {
        let streams = (try? device.streams) ?? []
        return streams.firstIndex(where: { (try? $0.direction) == .output }).map(UInt.init)
    }

    private func ownProcessObjects() -> [AudioObjectID] {
        (try? AudioHardwareSystem.shared.process(for: getpid())).map { [$0.id] } ?? []
    }

    private func makeObserver(on device: AudioHardwareDevice) -> SpikeEngine? {
        guard let uid = try? device.uid, let stream = firstOutputStreamIndex(device) else { return nil }
        return SpikeEngine(label: "observer", kind: .observe(excluding: ownProcessObjects(), stream: stream), deviceUID: uid, gain: 0)
    }

    private func setGain(_ engine: SpikeEngine, _ value: Float) {
        engine.setGain(value)
        log("[\(engine.label)] gain → \(value)")
    }

    /// Runs `work` on the HAL queue; returns the error description, if any.
    fileprivate func hal(_ work: @escaping @Sendable () throws -> Void) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            halQueue.async {
                do { try work(); cont.resume(returning: nil) } catch { cont.resume(returning: error.localizedDescription) }
            }
        }
    }

    /// `pmset -g assertions` lines that mention audio.
    fileprivate func audioAssertions() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n").filter {
            $0.localizedCaseInsensitiveContains("audio") || $0.contains("PreventUserIdleSystemSleep ") || $0.contains("PreventUserIdleDisplaySleep ")
        }
        return lines.map { "    " + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    func runScenario(_ name: String, args: [String]) async {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let system = AudioHardwareSystem.shared
        log("=== scenario \(name) ===")
        guard let device = try? system.defaultOutputDevice else { log("no default output device"); return }
        let deviceName = (try? device.name) ?? "?"
        let targetPID = value("--pid").flatMap { pid_t($0) }
        let target = targetPID.flatMap { try? system.process(for: $0) }
        if let targetPID {
            log("target pid \(targetPID) → process object \(target.map { "\($0.id)" } ?? "none"), running output: \(target.flatMap { try? $0.isRunningOutput } ?? false)")
        }

        switch name {
        case "devices":
            for d in outputDevices {
                let volumeAddress = PropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
                let hasVolume = d.hasProperty(address: volumeAddress) && ((try? d.isPropertySettable(address: volumeAddress)) ?? false)
                log("device \(d.id) \"\((try? d.name) ?? "?")\" uid \((try? d.uid) ?? "?") transport \(transportName((try? d.transportType) ?? 0)) hwVolume \(hasVolume) rate \((try? d.nominalSampleRate) ?? 0) stereo \((try? d.preferredOutputChannelsForStereo) ?? []) streams \(((try? d.streams) ?? []).map { (try? $0.direction) == .output ? "out" : "in" })")
            }
            log("default output: \(deviceName); default sound effects: \((try? system.defaultSoundEffectsDevice?.name) ?? "?")")

        case "s1":
            _ = await ensurePermission()
            guard let target, let uid = try? device.uid else { log("s1: needs --pid of a playing process"); return }
            var observer: SpikeEngine?
            if args.contains("--observe"), let o = makeObserver(on: device), await startEngine(o) {
                observer = o
                log("s1: observer baseline (tone should be visible as peak in ≈ 0.1)")
                await pause(2.5)
            }
            let engine = SpikeEngine(label: "S1", kind: .app(processes: [target.id]), deviceUID: uid, gain: 0.3)
            guard await startEngine(engine) else { return }
            log("s1: app tap on \(deviceName) at 0.3 (observer should drop to ≈ 0 if the tap mutes the app's own playback)")
            await pause(3.2)
            setGain(engine, 0.1)
            await pause(3.2)
            setGain(engine, 1.0)
            await pause(3.2)
            await stopEngine(engine)
            log("s1: app tap stopped (observer should show the tone again)")
            await pause(2.5)
            if let observer { await stopEngine(observer) }

        case "s1idle":
            let bundle = value("--bundle") ?? "com.apple.controlcenter"
            guard let process = ((try? system.processes) ?? []).first(where: { ((try? $0.bundleID) ?? nil) == bundle }),
                  let uid = try? device.uid else { log("s1idle: no process object for \(bundle)"); return }
            log("s1idle: \(bundle) object \(process.id), running output \((try? process.isRunningOutput) ?? false)")
            let engine = SpikeEngine(label: "S1idle", kind: .app(processes: [process.id]), deviceUID: uid, gain: 1)
            guard await startEngine(engine) else { return }
            await pause(2.2)
            await stopEngine(engine)

        case "s6":
            guard let target else { log("s6: needs --pid of a playing process"); return }
            let hold = value("--hold").flatMap(Double.init) ?? 5
            var observer: SpikeEngine?
            if args.contains("--observe"), let o = makeObserver(on: device), await startEngine(o) {
                observer = o
                log("s6: observer baseline")
                await pause(2.5)
            }
            let engine = SpikeEngine(label: "S6", kind: .mutedOnly(processes: [target.id]), deviceUID: "", gain: 1)
            guard await startEngine(engine) else { return }
            log("s6: muted tap active for \(hold) s (the tone should be silent)")
            await pause(hold)
            await stopEngine(engine)
            log("s6: muted tap destroyed (the tone should be back)")
            await pause(3)
            if let observer { await stopEngine(observer) }

        case "s2":
            _ = await ensurePermission()
            guard let uid = try? device.uid, let stream = firstOutputStreamIndex(device) else { log("s2: no output stream"); return }
            let excluded = ownProcessObjects()
            let engine = SpikeEngine(label: "S2", kind: .rest(excluding: excluded, excludeBundleIDs: [Bundle.main.bundleIdentifier ?? "com.freeaudio.taplab"], stream: stream), deviceUID: uid, gain: 0.3)
            log("s2: rest tap on \(deviceName) stream \(stream), excluding \(excluded)")
            guard await startEngine(engine) else { return }
            await pause(3.2)
            setGain(engine, 1.0)
            log("s2: gain 1.0, feedback check: peak in must stay at the source level, not grow")
            await pause(4.2)
            if let targetPID {
                kill(targetPID, SIGTERM)
                log("s2: stopped the source (pid \(targetPID)); peak in should fall to 0 (no recapture of our own output)")
                await pause(3.2)
            }
            if let otherUID = value("--switch-to"), let other = try? system.device(forUID: otherUID) {
                try? system.setDefaultOutputDevice(other)
                log("s2: default output → \((try? other.name) ?? otherUID)")
                await pause(3.2)
                try? system.setDefaultOutputDevice(device)
                log("s2: default output restored → \(deviceName)")
                await pause(2.2)
            }
            await stopEngine(engine)

        case "s4":
            // In-place kAudioTapPropertyDescription update: add a second process to a running tap.
            guard let target, let pid2 = value("--pid2").flatMap({ pid_t($0) }),
                  let second = try? system.process(for: pid2), let uid = try? device.uid else {
                log("s4: needs --pid and --pid2 of two playing processes"); return
            }
            let engine = SpikeEngine(label: "S4", kind: .app(processes: [target.id]), deviceUID: uid, gain: 0.3)
            guard await startEngine(engine) else { return }
            log("s4: tapping only \(target.id) (second tone \(second.id) plays at full level)")
            await pause(2.2)
            statsPaused = true
            _ = engine.takePeakIn()
            await pause(0.3)
            let before = engine.takePeakIn()
            _ = engine.resetMaxGap()
            let formatBefore = (try? engine.tap?.format).map { "\($0.mSampleRate) Hz \($0.mChannelsPerFrame) ch" } ?? "?"
            let started = HostTime.now
            let error = await hal { try engine.updateProcesses([target.id, second.id]) }
            let setMs = HostTime.ms(HostTime.now - started)
            log("s4: setDescription([\(target.id), \(second.id)]) took \(String(format: "%.1f", setMs)) ms, error: \(error ?? "none"); readback \(engine.tapProcesses() ?? [])")
            var captureMs: Double?
            for _ in 0..<100 {
                await pause(0.01)
                if engine.takePeakIn() > before * 1.4 { captureMs = HostTime.ms(HostTime.now - started); break }
            }
            let formatAfter = (try? engine.tap?.format).map { "\($0.mSampleRate) Hz \($0.mChannelsPerFrame) ch" } ?? "?"
            log("s4: peak before \(String(format: "%.4f", before)); second process captured after \(captureMs.map { String(format: "%.0f ms", $0) } ?? "NOT within 1 s"); longest callback gap \(String(format: "%.1f", HostTime.ms(engine.resetMaxGap()))) ms; format \(formatBefore) → \(formatAfter)")
            statsPaused = false
            log("s4: both tones now tapped at 0.3 (the second tone should have dropped too)")
            await pause(2.2)
            statsPaused = true
            log("s4: 100 alternating updates every 60 ms")
            var failures = 0
            _ = engine.resetMaxGap()
            for i in 0..<100 {
                let set: [AudioObjectID] = i % 2 == 0 ? [target.id] : [target.id, second.id]
                if await hal({ try engine.updateProcesses(set) }) != nil { failures += 1 }
                await pause(0.06)
            }
            let finalSet = engine.tapProcesses() ?? []
            log("s4: 100 updates, \(failures) failed; longest callback gap \(String(format: "%.1f", HostTime.ms(engine.resetMaxGap()))) ms; final readback \(finalSet); format \((try? engine.tap?.format).map { "\($0.mSampleRate) Hz \($0.mChannelsPerFrame) ch" } ?? "?")")
            statsPaused = false
            await pause(1.2)
            await stopEngine(engine)

        case "s5":
            // macOS 26 bundleIDs + processRestoreEnabled with two tone-player apps.
            _ = await ensurePermission()
            guard let toneA = value("--tone-a"), let toneB = value("--tone-b"), let uid = try? device.uid else {
                log("s5: needs --tone-a and --tone-b files"); return
            }
            let build = Bundle.main.bundleURL.deletingLastPathComponent()
            let appA = build.appendingPathComponent("ToneA.app"), appB = build.appendingPathComponent("ToneB.app")
            let idA = "com.freeaudio.taplab.tonea"
            func launch(_ url: URL, _ file: String) async -> NSRunningApplication? {
                let config = NSWorkspace.OpenConfiguration()
                config.arguments = [file]
                config.createsNewApplicationInstance = true
                config.activates = false
                return try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
            func object(_ app: NSRunningApplication?) -> AudioObjectID? {
                app.flatMap { try? system.process(for: $0.processIdentifier) }?.id
            }

            log("s5 V1: tap ToneA by process + bundle ID with restore on")
            let a1 = await launch(appA, toneA)
            await pause(1.5)
            guard let objA = object(a1) else { log("s5: ToneA has no process object"); a1?.terminate(); return }
            let engine = SpikeEngine(label: "S5", kind: .app(processes: [objA], bundleIDs: [idA], restore: true), deviceUID: uid, gain: 0.3)
            guard await startEngine(engine) else { a1?.terminate(); return }
            log("s5: ToneA (object \(objA)) tapped; expect peak in ≈ 0.10. readback \(engine.tapProcesses() ?? [])")
            await pause(2.2)
            a1?.terminate()
            log("s5: ToneA quit; expect peak in 0, tap still valid")
            await pause(2.2)
            log("s5: readback after quit \(engine.tapProcesses() ?? [])")
            let b = await launch(appB, toneB)
            log("s5: ToneB (other bundle ID, 0.05 tone) started; expect peak in 0 (not captured)")
            await pause(2.2)
            let a2 = await launch(appA, toneA)
            log("s5: ToneA relaunched as object \(object(a2).map { "\($0)" } ?? "?"); expect peak in ≈ 0.10 if restored")
            await pause(2.5)
            log("s5: readback after relaunch \(engine.tapProcesses() ?? [])")
            await stopEngine(engine)
            a2?.terminate()
            await pause(1)

            log("s5 V2: tap by bundle ID only, created before ToneA runs (ToneB still plays)")
            let engine2 = SpikeEngine(label: "S5b", kind: .app(processes: [], bundleIDs: [idA], restore: true), deviceUID: uid, gain: 0.3)
            if await startEngine(engine2) {
                await pause(1.2)
                let a3 = await launch(appA, toneA)
                log("s5: ToneA started as object \(object(a3).map { "\($0)" } ?? "?"); expect peak in ≈ 0.10 if bundle-ID taps pick up new processes")
                await pause(2.5)
                log("s5: readback \(engine2.tapProcesses() ?? [])")
                await stopEngine(engine2)
                a3?.terminate()
            }
            b?.terminate()

        case "s3":
            // Host-time crossfade handing an app between the rest tap and its own tap, then power.
            _ = await ensurePermission()
            guard let target, let uid = try? device.uid, let stream = firstOutputStreamIndex(device) else {
                log("s3: needs --pid of a playing process"); return
            }
            let own = ownProcessObjects()
            let deviceGain: Float = 0.5, appGain: Float = 0.3, fade = 0.05
            let toggles = value("--toggles").flatMap(Int.init) ?? 10
            func rest(_ label: String, excluding extra: [AudioObjectID]) -> SpikeEngine {
                SpikeEngine(label: label, kind: .rest(excluding: own + extra, excludeBundleIDs: [Bundle.main.bundleIdentifier ?? ""], stream: stream), deviceUID: uid, gain: 0)
            }
            func waitForCallbacks(_ list: [SpikeEngine]) async -> Bool {
                for _ in 0..<100 {
                    if list.allSatisfy({ $0.callbackCount > 2 }) { return true }
                    await pause(0.01)
                }
                return false
            }
            /// Sum of the target's gain over the engines that carry it, compared with the ideal ramp.
            func analyze(_ step: Int, carriers: [SpikeEngine], startHost: UInt64, from: Float, to: Float) {
                let duration = HostTime.ticks(fade)
                let window = (startHost - HostTime.ticks(0.03), startHost + duration + HostTime.ticks(0.03))
                let histories = carriers.map { $0.history(from: window.0, to: window.1) }
                guard let grid = histories.first, !grid.isEmpty else { log("s3 step \(step): no history"); return }
                let tolerance = HostTime.ticks(0.004)
                var worst: Float = 0, unmatched = 0, exactHostMatches = 0, samples = 0
                for (host, _) in grid {
                    var sum: Float = 0
                    for h in histories {
                        guard let nearest = h.min(by: { abs(Int64(bitPattern: $0.host &- host)) < abs(Int64(bitPattern: $1.host &- host)) }),
                              abs(Int64(bitPattern: nearest.host &- host)) <= Int64(tolerance) else { unmatched += 1; continue }
                        if nearest.host == host { exactHostMatches += 1 }
                        sum += nearest.gain
                    }
                    let p = Float(min(max(Double(Int64(bitPattern: host &- startHost)) / Double(duration), 0), 1))
                    worst = max(worst, abs(sum - (from + (to - from) * p)))
                    samples += 1
                }
                log(String(format: "s3 step %d: carried gain %.3f → %.3f over %d buffers, worst deviation %.4f, unmatched %d, identical host times %d/%d",
                           step, from, to, samples, worst, unmatched, exactHostMatches, samples * carriers.count))
            }

            var r = rest("R0", excluding: [])
            guard await startEngine(r) else { return }
            r.setGain(deviceGain)
            log("s3: rest tap at \(deviceGain); the tone alternates between \(deviceGain) (rest tap) and \(deviceGain * appGain) (own tap) every ~1 s, \(toggles * 2) handovers")
            await pause(1.5)
            statsPaused = true
            var x: SpikeEngine?
            for step in 0..<(toggles * 2) {
                if step % 2 == 0 {
                    let newX = SpikeEngine(label: "X\(step)", kind: .app(processes: [target.id]), deviceUID: uid, gain: 0)
                    let newR = rest("R\(step + 1)", excluding: [target.id])
                    // A tap whose processes are all silent gets no callbacks, so only wait for the
                    // engine whose source is playing; host-time ramps keep the others in step.
                    let okX = await startEngine(newX), okR = await startEngine(newR)
                    guard okX, okR, await waitForCallbacks([newX]) else { log("s3: engines didn't start"); await stopEngine(newX); await stopEngine(newR); break }
                    let t = HostTime.now + HostTime.ticks(0.03)
                    r.scheduleRamp(from: deviceGain, to: 0, startHost: t, seconds: fade)
                    newR.scheduleRamp(from: 0, to: deviceGain, startHost: t, seconds: fade)
                    newX.scheduleRamp(from: 0, to: deviceGain * appGain, startHost: t, seconds: fade)
                    await pause(0.15)
                    analyze(step, carriers: [r, newX], startHost: t, from: deviceGain, to: deviceGain * appGain)
                    await stopEngine(r)
                    r = newR
                    x = newX
                } else if let currentX = x {
                    let newR = rest("R\(step + 1)", excluding: [])
                    guard await startEngine(newR) else { log("s3: rest tap didn't start"); break }
                    await pause(0.03)
                    let t = HostTime.now + HostTime.ticks(0.03)
                    r.scheduleRamp(from: deviceGain, to: 0, startHost: t, seconds: fade)
                    currentX.scheduleRamp(from: deviceGain * appGain, to: 0, startHost: t, seconds: fade)
                    newR.scheduleRamp(from: 0, to: deviceGain, startHost: t, seconds: fade)
                    await pause(0.15)
                    analyze(step, carriers: [currentX, newR], startHost: t, from: deviceGain * appGain, to: deviceGain)
                    await stopEngine(currentX)
                    await stopEngine(r)
                    r = newR
                    x = nil
                }
                await pause(0.8)
            }
            statsPaused = false
            if let x { await stopEngine(x) }

            log("s3: power check, stopping the source; the rest tap keeps running on silence")
            if let targetPID { kill(targetPID, SIGTERM) }
            await pause(4)
            log("s3: pmset with the idle rest tap running:\n" + audioAssertions())
            let restarted = r
            _ = await hal { restarted.restartIO(log: { print($0) }) }
            log("s3: IO restarted on the idle rest tap (callbacks/s should drop to 0)")
            await pause(4)
            log("s3: pmset after the IO restart:\n" + audioAssertions())
            await stopEngine(r)
            await pause(3)
            log("s3: pmset after destroying it:\n" + audioAssertions())

        case "osd":
            showOSD(.volume, filled: 8)
            await pause(2.5)
            showOSD(.mute, filled: 0)
            await pause(3)

        default:
            log("unknown scenario \(name)")
        }
        log("=== scenario \(name) done ===")
        await pause(0.3)
    }
}

let app = NSApplication.shared
let delegate = TapLabDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

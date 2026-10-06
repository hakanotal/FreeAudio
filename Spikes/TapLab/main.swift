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
        for engine in engines where engine.aggregate != nil {
            var previous = previousCallbacks[ObjectIdentifier(engine)] ?? 0
            log(engine.statsLine(previousCallbacks: &previous))
            previousCallbacks[ObjectIdentifier(engine)] = previous
        }
    }

    // MARK: S9

    private func showOSD(_ image: TapLabOSDImage, filled: CUnsignedInt) {
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

let app = NSApplication.shared
let delegate = TapLabDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

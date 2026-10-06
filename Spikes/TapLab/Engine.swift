import CoreAudio
import Darwin
import Foundation
import Synchronization

// MARK: - Host time

enum HostTime {
    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1_000_000_000 * Double(info.denom) / Double(info.numer)
    }()

    static var now: UInt64 { mach_absolute_time() }
    static func ticks(_ seconds: Double) -> UInt64 { UInt64(seconds * ticksPerSecond) }
    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }
    static func ms(_ ticks: UInt64) -> Double { seconds(ticks) * 1000 }
    static var ticksPerSecondValue: Double { ticksPerSecond }
}

// MARK: - Real-time state

/// Shared between the main thread and the IOProc. Lives in manually allocated memory so the
/// IOProc only touches a raw pointer: no ARC, no allocation, no locks on the HAL thread.
/// Atomics carry values the main thread writes or reads; plain vars are touched by the IOProc only
/// (and by the main thread before AudioDeviceStart / after AudioDeviceStop).
struct RTState: ~Copyable {
    let targetGain = Atomic<UInt32>(Float(1).bitPattern)
    let callbacks = Atomic<UInt64>(0)
    let nonZeroCallbacks = Atomic<UInt64>(0)
    let lastHostTime = Atomic<UInt64>(0)
    let peakIn = Atomic<UInt32>(0)
    let peakOut = Atomic<UInt32>(0)
    let layoutCaptured = Atomic<Bool>(false)
    /// Longest interval between two callbacks (host ticks); the main thread resets it.
    let maxGap = Atomic<UInt64>(0)

    // Scheduled linear ramp in host time (crossfades). Duration 0 = off (one-pole ramp instead).
    let rampFrom = Atomic<UInt32>(0)
    let rampTo = Atomic<UInt32>(0)
    let rampStart = Atomic<UInt64>(0)
    let rampDuration = Atomic<UInt64>(0)

    // Gain history: IOProc appends (output host time, gain at buffer start); main reads after.
    let historyCount = Atomic<Int>(0)
    var historyHost: UnsafeMutablePointer<UInt64>?
    var historyGain: UnsafeMutablePointer<Float>?
    var historyCapacity = 0

    var currentGain: Float = 1
    var rampCoefficient: Float = 0.0007
    var ticksPerFrame: Double = 0
    var lastCallbackHost: UInt64 = 0
    var stereoLeft = 0
    var stereoRight = 1

    // One-shot buffer layout snapshot, published through `layoutCaptured`.
    var inBufferCount: UInt32 = 0
    var inChannels: UInt32 = 0
    var inBytes: UInt32 = 0
    var outBufferCount: UInt32 = 0
    var outChannels: UInt32 = 0
    var outBytes: UInt32 = 0
}

// MARK: - IOProc (real-time)

/// C IOProc. `clientData` is the engine's `UnsafeMutablePointer<RTState>`.
func tapLabIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let rt = clientData.assumingMemoryBound(to: RTState.self)
    let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let output = UnsafeMutableAudioBufferListPointer(outputData)

    let nowHost = now.pointee.mHostTime
    rt.pointee.callbacks.add(1, ordering: .relaxed)
    rt.pointee.lastHostTime.store(nowHost, ordering: .relaxed)
    if rt.pointee.lastCallbackHost != 0, nowHost > rt.pointee.lastCallbackHost {
        let gap = nowHost - rt.pointee.lastCallbackHost
        if gap > rt.pointee.maxGap.load(ordering: .relaxed) { rt.pointee.maxGap.store(gap, ordering: .relaxed) }
    }
    rt.pointee.lastCallbackHost = nowHost

    if !rt.pointee.layoutCaptured.load(ordering: .relaxed) {
        rt.pointee.inBufferCount = UInt32(input.count)
        rt.pointee.outBufferCount = UInt32(output.count)
        if let last = input.last {
            rt.pointee.inChannels = last.mNumberChannels
            rt.pointee.inBytes = last.mDataByteSize
        }
        if let first = output.first {
            rt.pointee.outChannels = first.mNumberChannels
            rt.pointee.outBytes = first.mDataByteSize
        }
        rt.pointee.layoutCaptured.store(true, ordering: .releasing)
    }

    // Gain source: a scheduled host-time ramp if one is set, else the one-pole ramp to the target.
    let outHost = outputTime.pointee.mHostTime
    let rampDuration = rt.pointee.rampDuration.load(ordering: .acquiring)
    let scheduled = rampDuration > 0 && outHost > 0
    let rampStart = Double(rt.pointee.rampStart.load(ordering: .relaxed))
    let rampFrom = Float(bitPattern: rt.pointee.rampFrom.load(ordering: .relaxed))
    let rampTo = Float(bitPattern: rt.pointee.rampTo.load(ordering: .relaxed))
    let ticksPerFrame = rt.pointee.ticksPerFrame
    let target = Float(bitPattern: rt.pointee.targetGain.load(ordering: .relaxed))
    let coefficient = rt.pointee.rampCoefficient

    func scheduledGain(frame: Int) -> Float {
        let t = Double(outHost) + Double(frame) * ticksPerFrame
        let p = Float(min(max((t - rampStart) / Double(rampDuration), 0), 1))
        return rampFrom + (rampTo - rampFrom) * p
    }

    var gain = scheduled ? scheduledGain(frame: 0) : rt.pointee.currentGain
    let gainAtStart = gain
    var peakIn: Float = 0
    var peakOut: Float = 0

    for outIndex in 0..<output.count {
        guard let outData = output[outIndex].mData else { continue }
        let outChannels = Int(max(output[outIndex].mNumberChannels, 1))
        let outSamples = Int(output[outIndex].mDataByteSize) / MemoryLayout<Float>.size
        let out = outData.assumingMemoryBound(to: Float.self)

        // The tap is the trailing input buffer(s); leading inputs are device hardware inputs.
        let inIndex = input.count >= output.count ? input.count - output.count + outIndex : outIndex
        guard inIndex < input.count, let inData = input[inIndex].mData else {
            for i in 0..<outSamples { out[i] = 0 }
            continue
        }
        let inChannels = Int(max(input[inIndex].mNumberChannels, 1))
        let inSamples = Int(input[inIndex].mDataByteSize) / MemoryLayout<Float>.size
        let src = UnsafePointer(inData.assumingMemoryBound(to: Float.self))
        let frames = min(inSamples / inChannels, outSamples / outChannels)

        for i in 0..<outSamples { out[i] = 0 }
        var frameGain = gain
        for frame in 0..<frames {
            if scheduled {
                frameGain = scheduledGain(frame: frame)
            } else {
                frameGain += (target - frameGain) * coefficient
            }
            let inBase = frame * inChannels
            let outBase = frame * outChannels
            for c in 0..<inChannels {
                let v = abs(src[inBase + c])
                if v > peakIn { peakIn = v }
            }
            if inChannels == outChannels {
                for c in 0..<inChannels { out[outBase + c] = src[inBase + c] * frameGain }
            } else if inChannels == 2 {
                let l = rt.pointee.stereoLeft < outChannels ? rt.pointee.stereoLeft : 0
                let r = rt.pointee.stereoRight < outChannels ? rt.pointee.stereoRight : min(1, outChannels - 1)
                out[outBase + l] = src[inBase] * frameGain
                out[outBase + r] = src[inBase + 1] * frameGain
            } else if inChannels == 1 {
                let l = rt.pointee.stereoLeft < outChannels ? rt.pointee.stereoLeft : 0
                let r = rt.pointee.stereoRight < outChannels ? rt.pointee.stereoRight : min(1, outChannels - 1)
                out[outBase + l] = src[inBase] * frameGain
                out[outBase + r] = src[inBase] * frameGain
            } else {
                for c in 0..<min(inChannels, outChannels) { out[outBase + c] = src[inBase + c] * frameGain }
            }
        }
        for i in 0..<(frames * outChannels) {
            let v = abs(out[i])
            if v > peakOut { peakOut = v }
        }
        if outIndex == output.count - 1 { gain = frameGain }
    }
    rt.pointee.currentGain = gain

    let index = rt.pointee.historyCount.load(ordering: .relaxed)
    if index < rt.pointee.historyCapacity, let hosts = rt.pointee.historyHost, let gains = rt.pointee.historyGain {
        hosts[index] = outHost
        gains[index] = gainAtStart
        rt.pointee.historyCount.store(index + 1, ordering: .releasing)
    }

    if peakIn > 0 { rt.pointee.nonZeroCallbacks.add(1, ordering: .relaxed) }
    if peakIn > Float(bitPattern: rt.pointee.peakIn.load(ordering: .relaxed)) {
        rt.pointee.peakIn.store(peakIn.bitPattern, ordering: .relaxed)
    }
    if peakOut > Float(bitPattern: rt.pointee.peakOut.load(ordering: .relaxed)) {
        rt.pointee.peakOut.store(peakOut.bitPattern, ordering: .relaxed)
    }
    return noErr
}

// MARK: - Engine

/// One tap, optionally wrapped in a private aggregate device with an IOProc.
/// `start`, `stop` and `updateProcesses` must run on the HAL queue.
final class SpikeEngine: @unchecked Sendable {
    enum Kind {
        /// Per-app tap (stereo mixdown of the given processes), muted while tapped. `bundleIDs`
        /// and `restore` exercise the macOS 26 follow-by-bundle-ID properties (S5).
        case app(processes: [AudioObjectID], bundleIDs: [String] = [], restore: Bool = false)
        /// Device-scoped "rest" tap: everything bound for the device except the given processes.
        case rest(excluding: [AudioObjectID], excludeBundleIDs: [String], stream: UInt)
        /// A muted tap with no aggregate device; nobody reads it (S6).
        case mutedOnly(processes: [AudioObjectID])
        /// Measurement only: an unmuted tap of everything bound for the device (except TapLab),
        /// played back at gain 0. Its "peak in" shows what other processes send to the device.
        case observe(excluding: [AudioObjectID], stream: UInt)
    }

    let label: String
    let kind: Kind
    let deviceUID: String
    let rt: UnsafeMutablePointer<RTState>
    private static let historyCapacity = 16_384
    private let historyHost: UnsafeMutablePointer<UInt64>
    private let historyGain: UnsafeMutablePointer<Float>

    private(set) var tap: AudioHardwareTap?
    private(set) var aggregate: AudioHardwareAggregateDevice?
    private var procID: AudioDeviceIOProcID?

    init(label: String, kind: Kind, deviceUID: String, gain: Float) {
        self.label = label
        self.kind = kind
        self.deviceUID = deviceUID
        historyHost = .allocate(capacity: Self.historyCapacity)
        historyGain = .allocate(capacity: Self.historyCapacity)
        rt = .allocate(capacity: 1)
        rt.initialize(to: RTState())
        rt.pointee.targetGain.store(gain.bitPattern, ordering: .relaxed)
        rt.pointee.currentGain = gain
        rt.pointee.historyHost = historyHost
        rt.pointee.historyGain = historyGain
        rt.pointee.historyCapacity = Self.historyCapacity
    }

    deinit {
        rt.deinitialize(count: 1)
        rt.deallocate()
        historyHost.deallocate()
        historyGain.deallocate()
    }

    var callbackCount: UInt64 { rt.pointee.callbacks.load(ordering: .relaxed) }

    func setGain(_ gain: Float) {
        rt.pointee.rampDuration.store(0, ordering: .releasing)
        rt.pointee.targetGain.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Linear gain ramp scheduled in host time, evaluated per frame from the output timestamp.
    func scheduleRamp(from: Float, to: Float, startHost: UInt64, seconds: Double) {
        rt.pointee.rampDuration.store(0, ordering: .releasing)
        rt.pointee.targetGain.store(to.bitPattern, ordering: .relaxed)
        rt.pointee.rampFrom.store(from.bitPattern, ordering: .relaxed)
        rt.pointee.rampTo.store(to.bitPattern, ordering: .relaxed)
        rt.pointee.rampStart.store(startHost, ordering: .relaxed)
        rt.pointee.rampDuration.store(HostTime.ticks(seconds), ordering: .releasing)
    }

    /// Recorded (output host time, gain) pairs in a host-time window.
    func history(from start: UInt64, to end: UInt64) -> [(host: UInt64, gain: Float)] {
        let count = rt.pointee.historyCount.load(ordering: .acquiring)
        return (0..<count).compactMap { i in
            historyHost[i] >= start && historyHost[i] <= end ? (historyHost[i], historyGain[i]) : nil
        }
    }

    func resetMaxGap() -> UInt64 { rt.pointee.maxGap.exchange(0, ordering: .relaxed) }

    /// The tap's current process list as Core Audio reports it.
    func tapProcesses() -> [AudioObjectID]? { (try? tap?.description)?.processes }

    /// Replaces the tap's process list in place (kAudioTapPropertyDescription). HAL queue only.
    func updateProcesses(_ processes: [AudioObjectID]) throws {
        guard let tap else { throw NSError(domain: "TapLab", code: 4, userInfo: [NSLocalizedDescriptionKey: "no tap"]) }
        let description = try tap.description
        description.processes = processes
        try tap.setDescription(description)
    }

    private static func ms(since start: UInt64) -> String {
        String(format: "%.1f ms", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    func start(log: (String) -> Void) throws {
        let system = AudioHardwareSystem.shared

        // 1. Tap description
        let description: CATapDescription
        switch kind {
        case .app(let processes, let bundleIDs, let restore):
            description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.muteBehavior = .mutedWhenTapped
            if !bundleIDs.isEmpty { description.bundleIDs = bundleIDs }
            if restore { description.isProcessRestoreEnabled = true }
        case .rest(let excluding, let bundleIDs, let stream):
            description = CATapDescription(excludingProcesses: excluding, deviceUID: deviceUID, stream: stream)
            if !bundleIDs.isEmpty { description.bundleIDs = bundleIDs }
            description.muteBehavior = .mutedWhenTapped
        case .mutedOnly(let processes):
            description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.muteBehavior = .muted
        case .observe(let excluding, let stream):
            description = CATapDescription(excludingProcesses: excluding, deviceUID: deviceUID, stream: stream)
            description.muteBehavior = .unmuted
        }
        description.name = "TapLab \(label)"
        description.uuid = UUID()
        description.isPrivate = true

        var t = DispatchTime.now().uptimeNanoseconds
        guard let tap = try system.makeProcessTap(description: description) else {
            throw NSError(domain: "TapLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "makeProcessTap returned nil"])
        }
        self.tap = tap
        let tapUID = try tap.uid
        let format = try tap.format
        log("[\(label)] tap \(tap.id) created in \(Self.ms(since: t)); uid matches description: \(tapUID == description.uuid.uuidString)")
        log("[\(label)] tap format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, flags 0x\(String(format.mFormatFlags, radix: 16)), \(format.mBitsPerChannel) bit")

        if case .mutedOnly = kind {
            log("[\(label)] muted tap active (no aggregate).")
            return
        }

        // 2. Aggregate device
        guard let device = try system.device(forUID: deviceUID) else {
            throw NSError(domain: "TapLab", code: 2, userInfo: [NSLocalizedDescriptionKey: "output device \(deviceUID) not found"])
        }
        let transport = try device.transportType
        let driftCompensation = !(transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
            || transport == kAudioDeviceTransportTypeVirtual)
        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "com.freeaudio.taplab.agg.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "TapLab \(label)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceClockDeviceKey: deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: driftCompensation,
            ]],
        ]
        t = DispatchTime.now().uptimeNanoseconds
        guard let aggregate = try system.makeAggregateDevice(description: composition) else {
            throw NSError(domain: "TapLab", code: 3, userInfo: [NSLocalizedDescriptionKey: "makeAggregateDevice returned nil"])
        }
        self.aggregate = aggregate
        log("[\(label)] aggregate \(aggregate.id) created in \(Self.ms(since: t)) (drift compensation \(driftCompensation))")

        // 3. Readiness, polled on this (background) queue.
        t = DispatchTime.now().uptimeNanoseconds
        var alive = false
        for _ in 0..<400 {
            if (try? aggregate.isAlive) == true { alive = true; break }
            usleep(5_000)
        }
        if !alive { log("[\(label)] aggregate NOT alive after \(Self.ms(since: t))") }

        // 4. Real-time state, seeded before start so the first buffer isn't at the wrong gain.
        let sampleRate = (try? aggregate.nominalSampleRate) ?? 48_000
        rt.pointee.rampCoefficient = Float(1 - exp(-1 / (sampleRate * 0.030)))
        rt.pointee.ticksPerFrame = HostTime.ticksPerSecondValue / sampleRate
        rt.pointee.currentGain = Float(bitPattern: rt.pointee.targetGain.load(ordering: .relaxed))
        let stereo = (try? device.preferredOutputChannelsForStereo) ?? [1, 2]
        if stereo.count == 2 {
            rt.pointee.stereoLeft = max(Int(stereo[0]) - 1, 0)
            rt.pointee.stereoRight = max(Int(stereo[1]) - 1, 0)
        }

        // 5. IOProc + start
        var newProcID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(aggregate.id, tapLabIOProc, UnsafeMutableRawPointer(rt), &newProcID)
        guard status == noErr, let newProcID else {
            throw NSError(domain: "TapLab", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AudioDeviceCreateIOProcID failed: \(status)"])
        }
        procID = newProcID
        t = DispatchTime.now().uptimeNanoseconds
        status = AudioDeviceStart(aggregate.id, newProcID)
        log("[\(label)] started (AudioDeviceStart -> \(status) in \(Self.ms(since: t)))")
        if status != noErr {
            throw NSError(domain: "TapLab", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AudioDeviceStart failed: \(status)"])
        }
    }

    func stop(log: (String) -> Void) {
        let system = AudioHardwareSystem.shared
        let t = DispatchTime.now().uptimeNanoseconds
        if let aggregate, let procID {
            AudioDeviceStop(aggregate.id, procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
        }
        procID = nil
        if let aggregate {
            do { try system.destroyAggregateDevice(aggregate) } catch { log("[\(label)] destroyAggregateDevice failed: \(error.localizedDescription)") }
        }
        aggregate = nil
        if let tap {
            do { try system.destroyProcessTap(tap) } catch { log("[\(label)] destroyProcessTap failed: \(error.localizedDescription)") }
        }
        tap = nil
        log("[\(label)] stopped and destroyed in \(Self.ms(since: t))")
    }

    /// AudioDeviceStop + AudioDeviceStart on the running aggregate, so IO waits for audio again
    /// (TapAutoStart). HAL queue only.
    func restartIO(log: (String) -> Void) {
        guard let aggregate, let procID else { return }
        let stop = AudioDeviceStop(aggregate.id, procID)
        let start = AudioDeviceStart(aggregate.id, procID)
        log("[\(label)] IO restarted (stop \(stop), start \(start))")
    }

    /// One stats line; resets the peak meters.
    func statsLine(previousCallbacks: inout UInt64) -> String {
        let callbacks = rt.pointee.callbacks.load(ordering: .relaxed)
        let delta = callbacks - previousCallbacks
        previousCallbacks = callbacks
        let peakIn = Float(bitPattern: rt.pointee.peakIn.exchange(0, ordering: .relaxed))
        let peakOut = Float(bitPattern: rt.pointee.peakOut.exchange(0, ordering: .relaxed))
        var line = String(format: "[%@] callbacks/s %llu  peak in %.4f  out %.4f  gain %.3f",
                          label, delta, peakIn, peakOut, rt.pointee.currentGain)
        if rt.pointee.layoutCaptured.load(ordering: .acquiring) {
            line += "  layout in \(rt.pointee.inBufferCount)×\(rt.pointee.inChannels)ch out \(rt.pointee.outBufferCount)×\(rt.pointee.outChannels)ch"
        }
        return line
    }

    /// Current peak since the last read, without the stats line (resets the input meter).
    func takePeakIn() -> Float { Float(bitPattern: rt.pointee.peakIn.exchange(0, ordering: .relaxed)) }
}

import CoreAudio
import Foundation
import os
import Synchronization

let engineLog = Logger(subsystem: "com.freeaudio.app", category: "engine")

// MARK: - Real-time state

/// Shared between the main thread and an engine's IOProc. Allocated manually so the IOProc only
/// touches a raw pointer (no ARC, allocation or locks on the HAL thread). Atomics carry what the
/// main thread writes or reads; plain vars belong to the IOProc (and to setup before
/// `AudioDeviceStart` / after `AudioDeviceDestroyIOProcID`).
struct RealtimeState: ~Copyable {
    let targetGain = Atomic<UInt32>(Float(1).bitPattern)
    // Host-time scheduled ramp (crossfades). Duration 0 = off.
    let rampFrom = Atomic<UInt32>(0)
    let rampTo = Atomic<UInt32>(0)
    let rampStart = Atomic<UInt64>(0)
    let rampDuration = Atomic<UInt64>(0)

    let callbacks = Atomic<UInt64>(0)
    let lastCallbackHost = Atomic<UInt64>(0)
    /// Last callback whose input was above the gate threshold.
    let lastSoundHost = Atomic<UInt64>(0)
    /// First callback after IO (re)started; silence is counted from here until the first sound.
    let ioResumedHost = Atomic<UInt64>(0)
    let everHadSound = Atomic<Bool>(false)
    let peakIn = Atomic<UInt32>(0)
    let peakOut = Atomic<UInt32>(0)

    // One-shot buffer layout snapshot for diagnostics, published by `layoutCaptured`.
    let layoutCaptured = Atomic<Bool>(false)
    var inBuffers: UInt32 = 0
    var inChannels: UInt32 = 0
    var outBuffers: UInt32 = 0
    var outChannels: UInt32 = 0
    var framesPerBuffer: UInt32 = 0

    var kernel = KernelState()
    var previousCallbackHost: UInt64 = 0
    /// A pause longer than this between callbacks means IO resumed (re-arms the output gate).
    var resumeGapTicks: UInt64 = HostClock.ticks(0.1)
}

/// The engines' IOProc. `clientData` is the engine's `UnsafeMutablePointer<RealtimeState>`.
/// A C function rather than a block: no captures, no ARC, and no inherited actor isolation
/// (an IOProc block created in a @MainActor context traps on the HAL thread under Swift 6).
func freeAudioIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let rt = clientData.assumingMemoryBound(to: RealtimeState.self)
    let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let output = UnsafeMutableAudioBufferListPointer(outputData)

    let nowHost = now.pointee.mHostTime
    let previous = rt.pointee.previousCallbackHost
    let resumed = previous == 0 || nowHost &- previous > rt.pointee.resumeGapTicks
    rt.pointee.previousCallbackHost = nowHost
    if resumed { rt.pointee.ioResumedHost.store(nowHost, ordering: .relaxed) }
    rt.pointee.callbacks.add(1, ordering: .relaxed)
    rt.pointee.lastCallbackHost.store(nowHost, ordering: .relaxed)

    var schedule: RampSchedule?
    let duration = rt.pointee.rampDuration.load(ordering: .acquiring)
    if duration > 0 {
        schedule = RampSchedule(
            from: Float(bitPattern: rt.pointee.rampFrom.load(ordering: .relaxed)),
            to: Float(bitPattern: rt.pointee.rampTo.load(ordering: .relaxed)),
            startHost: rt.pointee.rampStart.load(ordering: .relaxed),
            durationTicks: duration)
    }
    let target = Float(bitPattern: rt.pointee.targetGain.load(ordering: .relaxed))
    let result = RenderKernel.render(
        input: input, output: output, state: &rt.pointee.kernel, target: target,
        schedule: schedule, outputHostTime: outputTime.pointee.mHostTime, resumed: resumed)

    if result.peakIn > RenderKernel.gateThreshold {
        rt.pointee.lastSoundHost.store(nowHost, ordering: .relaxed)
        if !rt.pointee.everHadSound.load(ordering: .relaxed) { rt.pointee.everHadSound.store(true, ordering: .relaxed) }
    }
    if result.peakIn > Float(bitPattern: rt.pointee.peakIn.load(ordering: .relaxed)) {
        rt.pointee.peakIn.store(result.peakIn.bitPattern, ordering: .relaxed)
    }
    if result.peakOut > Float(bitPattern: rt.pointee.peakOut.load(ordering: .relaxed)) {
        rt.pointee.peakOut.store(result.peakOut.bitPattern, ordering: .relaxed)
    }
    if !rt.pointee.layoutCaptured.load(ordering: .relaxed) {
        rt.pointee.inBuffers = UInt32(input.count)
        rt.pointee.outBuffers = UInt32(output.count)
        rt.pointee.inChannels = input.last?.mNumberChannels ?? 0
        rt.pointee.outChannels = output.first?.mNumberChannels ?? 0
        if let first = output.first, first.mNumberChannels > 0 {
            rt.pointee.framesPerBuffer = first.mDataByteSize / 4 / first.mNumberChannels
        }
        rt.pointee.layoutCaptured.store(true, ordering: .releasing)
    }
    return noErr
}

// MARK: - Engine

/// One controlled app (or a device's rest audio, for software volume): a process tap and a private
/// aggregate device with an IOProc that plays the tapped audio at the engine's gain. `start`, `stop`, `updateProcesses` and
/// `restartIO` run on `HALQueue`; gain and stats are safe from any thread.
final class TapEngine: @unchecked Sendable {
    let spec: EngineSpec
    let rt: UnsafeMutablePointer<RealtimeState>

    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var procID: AudioDeviceIOProcID?

    init(spec: EngineSpec) {
        self.spec = spec
        rt = .allocate(capacity: 1)
        rt.initialize(to: RealtimeState())
        rt.pointee.targetGain.store(spec.gain.bitPattern, ordering: .relaxed)
        rt.pointee.kernel.gain = spec.gain
    }

    deinit {
        // Only reached after `stop()`: AudioDeviceDestroyIOProcID guarantees no callback is running.
        rt.deinitialize(count: 1)
        rt.deallocate()
    }

    private struct EngineError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: Gain and stats (any thread)

    func setGain(_ gain: Float) {
        rt.pointee.rampDuration.store(0, ordering: .releasing)
        rt.pointee.targetGain.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Linear ramp in host time, for crossfades between engines.
    func scheduleRamp(from: Float, to: Float, startHost: UInt64, seconds: Double) {
        rt.pointee.rampDuration.store(0, ordering: .releasing)
        rt.pointee.targetGain.store(to.bitPattern, ordering: .relaxed)
        rt.pointee.rampFrom.store(from.bitPattern, ordering: .relaxed)
        rt.pointee.rampTo.store(to.bitPattern, ordering: .relaxed)
        rt.pointee.rampStart.store(startHost, ordering: .relaxed)
        rt.pointee.rampDuration.store(HostClock.ticks(seconds), ordering: .releasing)
    }

    struct Stats: Sendable {
        var callbacks: UInt64
        var lastCallbackHost: UInt64
        var lastSoundHost: UInt64
        var ioResumedHost: UInt64
        var everHadSound: Bool
    }

    var stats: Stats {
        Stats(callbacks: rt.pointee.callbacks.load(ordering: .relaxed),
              lastCallbackHost: rt.pointee.lastCallbackHost.load(ordering: .relaxed),
              lastSoundHost: rt.pointee.lastSoundHost.load(ordering: .relaxed),
              ioResumedHost: rt.pointee.ioResumedHost.load(ordering: .relaxed),
              everHadSound: rt.pointee.everHadSound.load(ordering: .relaxed))
    }

    // MARK: Setup and teardown (HAL queue)

    func start() throws {
        let system = AudioHardwareSystem.shared
        let description: CATapDescription
        switch spec.kind {
        case .app:
            description = CATapDescription(stereoMixdownOfProcesses: spec.processObjectIDs)
            if !spec.bundleIDs.isEmpty {
                // Follow the app across relaunches (spike S5).
                description.bundleIDs = spec.bundleIDs
                description.isProcessRestoreEnabled = true
            }
        case .rest(let stream):
            // Everything bound for this device's stream except the excluded processes and bundle
            // IDs (FreeAudio and the controlled apps), spike S2. The stream index is global.
            description = CATapDescription(excludingProcesses: spec.processObjectIDs, deviceUID: spec.deviceUID, stream: stream)
            if !spec.bundleIDs.isEmpty { description.bundleIDs = spec.bundleIDs }
        }
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "FreeAudio \(spec.key)"
        description.uuid = UUID()

        guard let tap = try system.makeProcessTap(description: description) else {
            throw EngineError("makeProcessTap returned nil")
        }
        self.tap = tap
        guard let device = try system.device(forUID: spec.deviceUID) else {
            throw EngineError("output device \(spec.deviceUID) not found")
        }
        let transport = (try? device.transportType) ?? 0
        // Drift compensation on a Bluetooth or virtual source makes the HAL insert or drop a
        // sample every ~0.7 s, heard as a rhythmic crackle.
        let driftCompensation = !(transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
            || transport == kAudioDeviceTransportTypeVirtual)
        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey: freeAudioAggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceNameKey: "FreeAudio \(spec.key)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: spec.deviceUID,
            kAudioAggregateDeviceClockDeviceKey: spec.deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: spec.deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                // The tap's own UID property, not the description's UUID.
                kAudioSubTapUIDKey: try tap.uid,
                kAudioSubTapDriftCompensationKey: driftCompensation,
            ]],
        ]
        guard let aggregate = try system.makeAggregateDevice(description: composition) else {
            throw EngineError("makeAggregateDevice returned nil")
        }
        self.aggregate = aggregate

        // On macOS 27 the aggregate is alive at once (spike S1); keep a short poll as a safety net.
        var alive = false
        for _ in 0..<400 {
            if (try? aggregate.isAlive) == true { alive = true; break }
            usleep(5_000)
        }
        guard alive else { throw EngineError("aggregate device never became alive") }

        // Seed the render state before starting so the first buffer is at the right gain.
        let sampleRate = (try? aggregate.nominalSampleRate) ?? 48_000
        rt.pointee.kernel.configure(sampleRate: sampleRate, ticksPerSecond: HostClock.ticksPerSecond)
        rt.pointee.kernel.gain = Float(bitPattern: rt.pointee.targetGain.load(ordering: .relaxed))
        let stereo = (try? device.preferredOutputChannelsForStereo) ?? [1, 2]
        if stereo.count == 2 {
            rt.pointee.kernel.stereoLeft = max(Int(stereo[0]) - 1, 0)
            rt.pointee.kernel.stereoRight = max(Int(stereo[1]) - 1, 0)
        }

        var newProcID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(aggregate.id, freeAudioIOProc, UnsafeMutableRawPointer(rt), &newProcID)
        guard status == noErr, let newProcID else { throw EngineError("AudioDeviceCreateIOProcID failed (\(status))") }
        procID = newProcID
        disableDeviceInputStreams(aggregate: aggregate.id, procID: newProcID)

        status = AudioDeviceStart(aggregate.id, newProcID)
        guard status == noErr else { throw EngineError("AudioDeviceStart failed (\(status))") }
        engineLog.notice("\(self.spec.key, privacy: .public): engine on \(self.spec.deviceUID, privacy: .public) at \(sampleRate) Hz, gain \(self.spec.gain)")
    }

    /// Wrapping a duplex device (USB interface, headset) makes the aggregate open its inputs too,
    /// and macOS then shows the microphone indicator. Mark only the trailing tap stream as used.
    private func disableDeviceInputStreams(aggregate: AudioObjectID, procID: AudioDeviceIOProcID) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<UnsafeMutableRawPointer>.size + 8) else { return }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { buffer.deallocate() }
        // struct AudioHardwareIOProcStreamUsage { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        buffer.storeBytes(of: procID, as: AudioDeviceIOProcID.self)
        guard AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, buffer) == noErr else { return }
        let count = Int(buffer.load(fromByteOffset: 8, as: UInt32.self))
        // One input stream is just the tap. Never write a map with every stream off: the tap
        // would go silent.
        guard count > 1, size >= UInt32(12 + 4 * count) else { return }
        for index in 0..<count {
            buffer.storeBytes(of: UInt32(index == count - 1 ? 1 : 0), toByteOffset: 12 + 4 * index, as: UInt32.self)
        }
        let status = AudioObjectSetPropertyData(aggregate, &address, 0, nil, size, buffer)
        engineLog.info("\(self.spec.key, privacy: .public): disabled \(count - 1) device input stream(s) (\(status))")
    }

    /// Replaces the tap's processes and followed bundle IDs in place (spike S4): new helpers join
    /// a running tap without a rebuild.
    func updateTap(processObjectIDs: [UInt32], bundleIDs: [String]) throws {
        guard let tap, spec.kind == .app else { throw EngineError("no app tap") }
        let description = try tap.description
        description.processes = processObjectIDs
        if !bundleIDs.isEmpty {
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
        }
        try tap.setDescription(description)
    }

    /// Stop + start: lets an idle aggregate's IO stop (releasing coreaudiod's sleep assertion)
    /// while keeping the engine ready; `TapAutoStart` resumes IO when the app plays (spike S3).
    func restartIO() {
        guard let aggregate, let procID else { return }
        AudioDeviceStop(aggregate.id, procID)
        AudioDeviceStart(aggregate.id, procID)
    }

    func stop() {
        let system = AudioHardwareSystem.shared
        if let aggregate, let procID {
            AudioDeviceStop(aggregate.id, procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
        }
        procID = nil
        if let aggregate { try? system.destroyAggregateDevice(aggregate) }
        aggregate = nil
        if let tap { try? system.destroyProcessTap(tap) }
        tap = nil
    }

    /// Buffer layout of the first callback, once there has been one.
    var layoutDescription: String? {
        guard rt.pointee.layoutCaptured.load(ordering: .acquiring) else { return nil }
        return "in \(rt.pointee.inBuffers)×\(rt.pointee.inChannels)ch, out \(rt.pointee.outBuffers)×\(rt.pointee.outChannels)ch, \(rt.pointee.framesPerBuffer) frames"
    }
}

import CoreAudio
import Foundation

/// Render state owned by one engine's IOProc. Plain values only: it lives inside the engine's
/// manually allocated real-time state and is mutated on the HAL thread.
struct KernelState: Sendable {
    /// Current (ramped) gain.
    var gain: Float = 1
    /// One-pole smoothing per frame: `1 - exp(-1 / (sampleRate * 0.030))` (30 ms).
    var rampCoefficient: Float = 0.0007
    /// 0-based output channels for stereo (the device's preferred pair), counted across the
    /// device's output streams in order, as Core Audio numbers them.
    var stereoLeft = 0
    var stereoRight = 1
    /// Host ticks per frame, for host-time scheduled ramps.
    var ticksPerFrame: Double = 0
    // Output gate: after IO (re)starts the HAL can hand over a stale buffer. Output stays silent
    // until real input arrives, then fades in over `gateFadeFrames` (40 ms).
    var gateOpen = false
    var gatePosition = 0
    var gateFadeFrames = 1920

    static func coefficient(sampleRate: Double, timeConstant: Double = 0.030) -> Float {
        Float(1 - exp(-1 / (sampleRate * timeConstant)))
    }

    /// A rate of 0 (a device mid-reconfiguration) is treated as 48 kHz: it would make
    /// `ticksPerFrame` infinite and the gain NaN.
    mutating func configure(sampleRate: Double, ticksPerSecond: Double) {
        let rate = sampleRate > 0 && sampleRate.isFinite ? sampleRate : 48_000
        rampCoefficient = Self.coefficient(sampleRate: rate)
        ticksPerFrame = ticksPerSecond / rate
        gateFadeFrames = max(Int(rate * 0.040), 1)
    }

    /// The gate has opened and finished its fade-in.
    var gateFullyOpen: Bool { gateOpen && gatePosition >= gateFadeFrames }
}

/// A linear gain ramp scheduled in host time (crossfades between engines). Every engine computes
/// its gain per frame from its own output timestamp, so engines on the same device stay in step.
struct RampSchedule: Sendable, Equatable {
    var from: Float
    var to: Float
    var startHost: UInt64
    var durationTicks: UInt64

    func gain(atHost host: Double) -> Float {
        guard durationTicks > 0 else { return to }
        let p = Float(min(max((host - Double(startHost)) / Double(durationTicks), 0), 1))
        return from + (to - from) * p
    }

    /// The ramp is over at `host`: from then on the gain is simply `to`.
    func hasEnded(atHost host: UInt64) -> Bool {
        durationTicks == 0 || (host >= startHost && host - startHost >= durationTicks)
    }
}

struct KernelResult: Sendable, Equatable {
    /// Peak of the tap input (drives the gate and idle detection).
    var peakIn: Float = 0
}

/// The per-buffer audio processing of a tap engine. Real-time safe: no allocation, no locks,
/// no Objective-C or Swift runtime calls that can allocate.
enum RenderKernel {
    static let gateThreshold: Float = 0.0001
    /// Samples above this are soft-limited (while boosting) so audio never exceeds full scale.
    static let limiterThreshold: Float = 0.9
    /// Above unity the limiter blends in over this much gain, so a drag through 100% doesn't step.
    static let limiterBlend: Float = 0.05
    /// A converging gain ramp snaps to its target this close to it.
    static let snapDistance: Float = 1e-6

    /// Soft limiter: unchanged up to the threshold, then a tanh knee that approaches ±1.
    /// Continuous in value and slope at the threshold.
    @inline(__always)
    static func softLimit(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > limiterThreshold else { return x }
        let headroom = 1 - limiterThreshold
        let limited = limiterThreshold + headroom * tanh((magnitude - limiterThreshold) / headroom)
        return x < 0 ? -limited : limited
    }

    /// How much of the limiter applies at `gain`: none at or below unity (audio passes untouched),
    /// fully from 1 + `limiterBlend`.
    @inline(__always)
    static func limiterWeight(gain: Float) -> Float {
        gain <= 1 ? 0 : min((gain - 1) / limiterBlend, 1)
    }

    @inline(__always)
    static func amplify(_ x: Float, gain: Float, limit: Float) -> Float {
        let y = x * gain
        return limit == 0 ? y : y + limit * (softLimit(y) - y)
    }

    /// Half-cosine fade-in factor for the output gate.
    @inline(__always)
    static func gateGain(position: Int, fadeFrames: Int) -> Float {
        guard position < fadeFrames else { return 1 }
        return 0.5 - 0.5 * cos(Float.pi * Float(position) / Float(fadeFrames))
    }

    /// One one-pole step towards `target`. Float stalls short of the target (an update stops
    /// changing the value about 1e-4 away), so a step that makes no progress, or lands within
    /// `snapDistance`, finishes the ramp.
    @inline(__always)
    static func ramp(_ gain: Float, towards target: Float, coefficient: Float) -> Float {
        let next = gain + (target - gain) * coefficient
        return next == gain || abs(target - next) < snapDistance ? target : next
    }

    /// IO resumed after a pause: the gap since the previous callback is longer than
    /// `minimumGapTicks` and than three buffers (large buffers must not look like pauses).
    static func isResume(previousHost: UInt64, nowHost: UInt64, frames: Int, ticksPerFrame: Double, minimumGapTicks: UInt64) -> Bool {
        guard previousHost != 0 else { return true }
        let bufferGap = Double(max(frames, 0)) * ticksPerFrame * 3
        let threshold = bufferGap.isFinite ? max(minimumGapTicks, UInt64(bufferGap)) : minimumGapTicks
        return nowHost &- previousHost > threshold
    }

    // MARK: Routing

    /// Where one callback's tap audio goes. Plain pointers and counts (no allocation).
    struct Route {
        enum Mode { case pair, downmix, copy }
        var mode: Mode
        var src: UnsafeMutablePointer<Float>
        var inChannels: Int
        /// `pair`: left slot; `downmix`: the one slot; `copy`: channel 0 of the target buffer.
        var leftOut: UnsafeMutablePointer<Float>
        var leftStride: Int
        var leftChannel: Int
        var rightOut: UnsafeMutablePointer<Float>
        var rightStride: Int
        var rightChannel: Int
        /// `copy`: channels copied one to one.
        var copyChannels: Int
        var frames: Int

        /// Peak of one input frame.
        @inline(__always)
        func peak(frame: Int) -> Float {
            let base = frame * inChannels
            var peak: Float = 0
            for c in 0..<inChannels {
                let v = abs(src[base + c])
                if v > peak { peak = v }
            }
            return peak
        }

        /// Writes one frame at `gain` and returns the input frame's peak.
        @inline(__always)
        func write(frame: Int, gain: Float, limit: Float) -> Float {
            let inBase = frame * inChannels
            switch mode {
            case .pair:
                let l = src[inBase]
                let r = inChannels > 1 ? src[inBase + 1] : l
                leftOut[frame * leftStride + leftChannel] = amplify(l, gain: gain, limit: limit)
                rightOut[frame * rightStride + rightChannel] = amplify(r, gain: gain, limit: limit)
                return max(abs(l), abs(r))
            case .downmix:
                let l = src[inBase]
                let r = inChannels > 1 ? src[inBase + 1] : l
                leftOut[frame * leftStride + leftChannel] = amplify((l + r) * 0.5, gain: gain, limit: limit)
                return max(abs(l), abs(r))
            case .copy:
                let outBase = frame * leftStride
                var peak: Float = 0
                for c in 0..<inChannels {
                    let v = src[inBase + c]
                    if abs(v) > peak { peak = abs(v) }
                    if c < copyChannels { leftOut[outBase + c] = amplify(v, gain: gain, limit: limit) }
                }
                return peak
            }
        }
    }

    private struct Slot: Equatable {
        var buffer: Int
        var channel: Int
    }

    /// The output buffer and channel holding device channel `channel` (0-based, counted across
    /// the buffers in order).
    private static func slot(forDeviceChannel channel: Int, in output: UnsafeMutableAudioBufferListPointer) -> Slot? {
        var base = 0
        for b in 0..<output.count {
            let count = Int(output[b].mNumberChannels)
            if channel >= base, channel < base + count { return Slot(buffer: b, channel: channel - base) }
            base += count
        }
        return nil
    }

    @inline(__always)
    private static func frameCount(_ buffer: AudioBuffer) -> Int {
        Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / Int(max(buffer.mNumberChannels, 1))
    }

    /// The tap is always the last input buffer: an aggregate holds exactly one tap, and any
    /// leading input buffers are the device's own inputs (USB duplex). Stereo (or mono) goes to
    /// the device's preferred stereo pair, which can sit in any output buffer; a one-channel
    /// target gets a downmix. A multichannel tap (a rest tap of a whole stream) is copied into
    /// the first output buffer, the stream it taps.
    static func makeRoute(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer, state: KernelState) -> Route? {
        guard let source = input.last, let srcData = source.mData, output.count > 0 else { return nil }
        let src = srcData.assumingMemoryBound(to: Float.self)
        let inChannels = Int(max(source.mNumberChannels, 1))
        var frames = frameCount(source)

        if inChannels > 2 {
            let target = output[0]
            guard let data = target.mData else { return nil }
            frames = min(frames, frameCount(target))
            let out = data.assumingMemoryBound(to: Float.self)
            let stride = Int(max(target.mNumberChannels, 1))
            return Route(mode: .copy, src: src, inChannels: inChannels,
                         leftOut: out, leftStride: stride, leftChannel: 0,
                         rightOut: out, rightStride: stride, rightChannel: 0,
                         copyChannels: min(inChannels, stride), frames: frames)
        }

        let firstChannels = Int(max(output[0].mNumberChannels, 1))
        let left = slot(forDeviceChannel: state.stereoLeft, in: output) ?? Slot(buffer: 0, channel: 0)
        let right = slot(forDeviceChannel: state.stereoRight, in: output) ?? Slot(buffer: 0, channel: min(1, firstChannels - 1))
        guard let leftData = output[left.buffer].mData, let rightData = output[right.buffer].mData else { return nil }
        frames = min(frames, frameCount(output[left.buffer]), frameCount(output[right.buffer]))
        return Route(mode: left == right ? .downmix : .pair, src: src, inChannels: inChannels,
                     leftOut: leftData.assumingMemoryBound(to: Float.self),
                     leftStride: Int(max(output[left.buffer].mNumberChannels, 1)), leftChannel: left.channel,
                     rightOut: rightData.assumingMemoryBound(to: Float.self),
                     rightStride: Int(max(output[right.buffer].mNumberChannels, 1)), rightChannel: right.channel,
                     copyChannels: 0, frames: frames)
    }

    // MARK: Render

    /// Copies the tap input to the device output with gain, gate and limiter.
    /// - Parameters:
    ///   - target: gain the one-pole ramp moves towards (ignored while `schedule` is set)
    ///   - schedule: host-time ramp, used for crossfades
    ///   - outputHostTime: host time of the output buffer's first frame
    ///   - resumed: IO just (re)started after a pause; re-arms the output gate
    static func render(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        state: inout KernelState,
        target: Float,
        schedule: RampSchedule? = nil,
        outputHostTime: UInt64 = 0,
        resumed: Bool = false
    ) -> KernelResult {
        if resumed {
            state.gateOpen = false
            state.gatePosition = 0
            // Gain changes made while IO was stopped (an idle restart, a pre-armed engine) only
            // moved the target; start there instead of ramping from the stale gain. The gate is
            // closed, so this doesn't step.
            if schedule == nil { state.gain = target }
        }
        // Only the routed slots get audio; everything else stays silent.
        for o in 0..<output.count {
            if let data = output[o].mData { memset(data, 0, Int(output[o].mDataByteSize)) }
        }
        guard let route = makeRoute(input: input, output: output, state: state), route.frames > 0 else { return KernelResult() }
        var result = KernelResult()

        // Steady state (nearly always): constant gain, gate open, no crossfade.
        if schedule == nil, state.gain == target, state.gateFullyOpen {
            if target == 0 {
                for frame in 0..<route.frames {
                    let p = route.peak(frame: frame)
                    if p > result.peakIn { result.peakIn = p }
                }
            } else {
                let limit = limiterWeight(gain: target)
                for frame in 0..<route.frames {
                    let p = route.write(frame: frame, gain: target, limit: limit)
                    if p > result.peakIn { result.peakIn = p }
                }
            }
            return result
        }

        // Ramps, crossfades and the gate: per frame.
        for frame in 0..<route.frames {
            if let schedule {
                state.gain = schedule.gain(atHost: Double(outputHostTime) + Double(frame) * state.ticksPerFrame)
            } else if state.gain != target {
                state.gain = ramp(state.gain, towards: target, coefficient: state.rampCoefficient)
            }

            var framePeak: Float = -1
            if !state.gateOpen {
                framePeak = route.peak(frame: frame)
                if framePeak > gateThreshold {
                    state.gateOpen = true
                    state.gatePosition = 0
                }
            }
            var gain: Float = 0
            if state.gateOpen {
                gain = state.gain * gateGain(position: state.gatePosition, fadeFrames: state.gateFadeFrames)
                if state.gatePosition < state.gateFadeFrames { state.gatePosition += 1 }
            }
            if gain != 0 {
                let p = route.write(frame: frame, gain: gain, limit: limiterWeight(gain: gain))
                if framePeak < 0 { framePeak = p }
            } else if framePeak < 0 {
                framePeak = route.peak(frame: frame)
            }
            if framePeak > result.peakIn { result.peakIn = framePeak }
        }
        return result
    }
}

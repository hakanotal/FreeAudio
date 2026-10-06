import CoreAudio
import Foundation

/// Render state owned by one engine's IOProc. Plain values only: it lives inside the engine's
/// manually allocated real-time state and is mutated on the HAL thread.
struct KernelState: Sendable {
    /// Current (ramped) gain.
    var gain: Float = 1
    /// One-pole smoothing per frame: `1 - exp(-1 / (sampleRate * 0.030))` (30 ms).
    var rampCoefficient: Float = 0.0007
    /// 0-based output channels for stereo (the device's preferred pair).
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

    mutating func configure(sampleRate: Double, ticksPerSecond: Double) {
        rampCoefficient = Self.coefficient(sampleRate: sampleRate)
        ticksPerFrame = ticksPerSecond / sampleRate
        gateFadeFrames = max(Int(sampleRate * 0.040), 1)
    }
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
}

struct KernelResult: Sendable, Equatable {
    var peakIn: Float = 0
    var peakOut: Float = 0
}

/// The per-buffer audio processing of a tap engine. Real-time safe: no allocation, no locks,
/// no Objective-C or Swift runtime calls that can allocate.
enum RenderKernel {
    static let gateThreshold: Float = 0.0001
    /// Samples above this are soft-limited so boosted audio never exceeds full scale.
    static let limiterThreshold: Float = 0.9

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

    /// Half-cosine fade-in factor for the output gate.
    @inline(__always)
    static func gateGain(position: Int, fadeFrames: Int) -> Float {
        guard position < fadeFrames else { return 1 }
        return 0.5 - 0.5 * cos(Float.pi * Float(position) / Float(fadeFrames))
    }

    /// Index of the input buffer feeding output buffer `outIndex`: with more input than output
    /// buffers, the tap is the trailing input buffer(s) and the leading ones are device inputs.
    @inline(__always)
    static func inputIndex(forOutput outIndex: Int, inputCount: Int, outputCount: Int) -> Int {
        inputCount >= outputCount ? inputCount - outputCount + outIndex : outIndex
    }

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
        }

        // Clear the output and find the frame count every mapped buffer pair can serve.
        var frames = Int.max
        for o in 0..<output.count {
            if let data = output[o].mData {
                memset(data, 0, Int(output[o].mDataByteSize))
            }
            let i = inputIndex(forOutput: o, inputCount: input.count, outputCount: output.count)
            guard i < input.count, input[i].mData != nil, output[o].mData != nil else { continue }
            let inChannels = Int(max(input[i].mNumberChannels, 1))
            let outChannels = Int(max(output[o].mNumberChannels, 1))
            let inFrames = Int(input[i].mDataByteSize) / MemoryLayout<Float>.size / inChannels
            let outFrames = Int(output[o].mDataByteSize) / MemoryLayout<Float>.size / outChannels
            frames = min(frames, inFrames, outFrames)
        }
        guard frames != Int.max, frames > 0 else { return KernelResult() }

        var result = KernelResult()
        for frame in 0..<frames {
            if let schedule {
                state.gain = schedule.gain(atHost: Double(outputHostTime) + Double(frame) * state.ticksPerFrame)
            } else {
                state.gain += (target - state.gain) * state.rampCoefficient
            }

            var framePeak: Float = 0
            for o in 0..<output.count {
                let i = inputIndex(forOutput: o, inputCount: input.count, outputCount: output.count)
                guard i < input.count, let inData = input[i].mData else { continue }
                let src = inData.assumingMemoryBound(to: Float.self)
                let inChannels = Int(max(input[i].mNumberChannels, 1))
                let base = frame * inChannels
                for c in 0..<inChannels {
                    let v = abs(src[base + c])
                    if v > framePeak { framePeak = v }
                }
            }
            if framePeak > result.peakIn { result.peakIn = framePeak }

            if !state.gateOpen, framePeak > gateThreshold {
                state.gateOpen = true
                state.gatePosition = 0
            }
            var gain: Float = 0
            if state.gateOpen {
                gain = state.gain * gateGain(position: state.gatePosition, fadeFrames: state.gateFadeFrames)
                if state.gatePosition < state.gateFadeFrames { state.gatePosition += 1 }
            }
            guard gain != 0 else { continue }

            for o in 0..<output.count {
                let i = inputIndex(forOutput: o, inputCount: input.count, outputCount: output.count)
                guard i < input.count, let inData = input[i].mData, let outData = output[o].mData else { continue }
                let src = inData.assumingMemoryBound(to: Float.self)
                let out = outData.assumingMemoryBound(to: Float.self)
                let inChannels = Int(max(input[i].mNumberChannels, 1))
                let outChannels = Int(max(output[o].mNumberChannels, 1))
                let inBase = frame * inChannels
                let outBase = frame * outChannels

                if inChannels == outChannels {
                    for c in 0..<inChannels {
                        out[outBase + c] = softLimit(src[inBase + c] * gain)
                    }
                } else if inChannels <= 2 {
                    // Stereo (or mono, duplicated) into the device's preferred stereo pair.
                    let left = state.stereoLeft < outChannels ? state.stereoLeft : 0
                    let right = state.stereoRight < outChannels ? state.stereoRight : min(1, outChannels - 1)
                    out[outBase + left] = softLimit(src[inBase] * gain)
                    out[outBase + right] = softLimit(src[inBase + (inChannels == 2 ? 1 : 0)] * gain)
                } else {
                    for c in 0..<min(inChannels, outChannels) {
                        out[outBase + c] = softLimit(src[inBase + c] * gain)
                    }
                }
                for c in 0..<outChannels {
                    let v = abs(out[outBase + c])
                    if v > result.peakOut { result.peakOut = v }
                }
            }
        }
        return result
    }
}

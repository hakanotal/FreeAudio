import CoreAudio
import Foundation
import Testing
@testable import FreeAudioCore

/// Owns interleaved Float buffers wrapped in an AudioBufferList for the duration of a test.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []
    let frames: Int

    init(channels: [Int], frames: Int, fill: (Int, Int, Int) -> Float = { _, _, _ in 0 }) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: channels.count)
        for (b, ch) in channels.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * ch)
            for f in 0..<frames { for c in 0..<ch { data[f * ch + c] = fill(b, f, c) } }
            storage.append(data)
            list[b] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(frames * ch * 4), mData: data)
        }
    }

    func sample(buffer: Int, frame: Int, channel: Int) -> Float {
        let ch = Int(list[buffer].mNumberChannels)
        return storage[buffer][frame * ch + channel]
    }

    /// Largest absolute sample in one buffer.
    func peak(buffer: Int) -> Float {
        let count = frames * Int(list[buffer].mNumberChannels)
        return (0..<count).reduce(0) { max($0, abs(storage[buffer][$1])) }
    }

    /// Every sample of every buffer, in order.
    var samples: [Float] {
        (0..<list.count).flatMap { b in (0..<frames * Int(list[b].mNumberChannels)).map { storage[b][$0] } }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

struct RenderKernelTests {
    private func openState(gain: Float = 1) -> KernelState {
        var state = KernelState()
        state.configure(sampleRate: 48_000, ticksPerSecond: 48_000)
        state.gain = gain
        state.gateOpen = true
        state.gatePosition = state.gateFadeFrames
        return state
    }

    @Test func stereoCopyAtUnityGain() {
        let input = TestBufferList(channels: [2], frames: 64) { _, f, c in c == 0 ? 0.5 : -0.25 }
        let output = TestBufferList(channels: [2], frames: 64)
        var state = openState()
        let result = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1)
        #expect(output.sample(buffer: 0, frame: 63, channel: 0) == 0.5)
        #expect(output.sample(buffer: 0, frame: 63, channel: 1) == -0.25)
        #expect(result.peakIn == 0.5)
    }

    @Test func rampFollowsThirtyMillisecondTimeConstant() {
        let frames = 48_000 * 140 / 1000  // 140 ms
        let input = TestBufferList(channels: [2], frames: frames) { _, _, _ in 0.5 }
        let output = TestBufferList(channels: [2], frames: frames)
        var state = openState(gain: 1)
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 0)
        let at30ms = output.sample(buffer: 0, frame: 1440, channel: 0) / 0.5
        #expect(abs(at30ms - 0.368) < 0.01)
        #expect(state.gain < 0.01)
    }

    @Test func gateHoldsSilenceThenFadesIn() {
        let input = TestBufferList(channels: [2], frames: 4000) { _, f, _ in f < 100 ? 0 : 0.5 }
        let output = TestBufferList(channels: [2], frames: 4000)
        var state = KernelState()
        state.configure(sampleRate: 48_000, ticksPerSecond: 48_000)
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1)
        #expect(output.sample(buffer: 0, frame: 50, channel: 0) == 0)
        #expect(output.sample(buffer: 0, frame: 100, channel: 0) == 0)  // fade starts at 0
        let mid = output.sample(buffer: 0, frame: 100 + 960, channel: 0)
        #expect(abs(mid - 0.25) < 0.01)  // half way through the 40 ms fade
        #expect(abs(output.sample(buffer: 0, frame: 3999, channel: 0) - 0.5) < 0.0001)
    }

    @Test func resumeRearmsTheGate() {
        let input = TestBufferList(channels: [2], frames: 10) { _, _, _ in 0.5 }
        let output = TestBufferList(channels: [2], frames: 10)
        var state = openState()
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1, resumed: true)
        #expect(output.sample(buffer: 0, frame: 0, channel: 0) == 0)
        #expect(state.gatePosition == 10)
    }

    @Test func resumeStartsAtTheTarget() {
        // Muted while IO was stopped: nothing of the old level may leak when playback resumes.
        let input = TestBufferList(channels: [2], frames: 4800) { _, _, _ in 0.5 }
        let output = TestBufferList(channels: [2], frames: 4800)
        var state = openState(gain: 1)
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 0, resumed: true)
        #expect(output.peak(buffer: 0) == 0)
        #expect(state.gain == 0)
    }

    @Test func stereoGoesToThePreferredPair() {
        let input = TestBufferList(channels: [2], frames: 8) { _, _, c in c == 0 ? 0.1 : 0.2 }
        let output = TestBufferList(channels: [4], frames: 8)
        var state = openState()
        state.stereoLeft = 2
        state.stereoRight = 3
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1)
        #expect(output.sample(buffer: 0, frame: 7, channel: 0) == 0)
        #expect(output.sample(buffer: 0, frame: 7, channel: 2) == 0.1)
        #expect(output.sample(buffer: 0, frame: 7, channel: 3) == 0.2)
    }

    @Test func monoIsDuplicated() {
        let input = TestBufferList(channels: [1], frames: 8) { _, _, _ in 0.3 }
        let output = TestBufferList(channels: [2], frames: 8)
        var state = openState()
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1)
        #expect(output.sample(buffer: 0, frame: 7, channel: 0) == 0.3)
        #expect(output.sample(buffer: 0, frame: 7, channel: 1) == 0.3)
    }

    @Test func tapIsTheTrailingInputBuffer() {
        // Duplex device: buffer 0 is the device's microphone, buffer 1 the tap.
        let input = TestBufferList(channels: [1, 2], frames: 8) { b, _, _ in b == 0 ? 0.9 : 0.4 }
        let output = TestBufferList(channels: [2], frames: 8)
        var state = openState()
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1)
        #expect(output.sample(buffer: 0, frame: 7, channel: 0) == 0.4)
    }

    @Test func boostedAudioNeverExceedsFullScale() {
        let input = TestBufferList(channels: [2], frames: 64) { _, f, _ in f % 2 == 0 ? 0.95 : -0.95 }
        let output = TestBufferList(channels: [2], frames: 64)
        var state = openState(gain: 2)
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 2)
        #expect(output.peak(buffer: 0) <= 1)
        #expect(output.peak(buffer: 0) > 0.9)
    }

    @Test func audioAtOrBelowUnityIsUntouched() {
        // The limiter only acts while boosting: full-scale peaks pass unchanged at 100%.
        let input = TestBufferList(channels: [2], frames: 16) { _, f, _ in f % 2 == 0 ? 0.95 : -1 }
        let output = TestBufferList(channels: [2], frames: 16)
        var state = openState(gain: 1)
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1)
        #expect(output.sample(buffer: 0, frame: 0, channel: 0) == 0.95)
        #expect(output.sample(buffer: 0, frame: 1, channel: 1) == -1)

        let quieter = TestBufferList(channels: [2], frames: 16)
        var half = openState(gain: 0.8)
        _ = RenderKernel.render(input: input.list, output: quieter.list, state: &half, target: 0.8)
        #expect(quieter.sample(buffer: 0, frame: 1, channel: 0) == -0.8)
    }

    @Test func limiterBlendsInAboveUnity() {
        #expect(RenderKernel.limiterWeight(gain: 1) == 0)
        #expect(RenderKernel.limiterWeight(gain: 0.5) == 0)
        #expect(abs(RenderKernel.limiterWeight(gain: 1.05) - 1) < 0.0001)
        #expect(RenderKernel.limiterWeight(gain: 1.06) == 1)
        #expect(RenderKernel.limiterWeight(gain: 2) == 1)
        // Continuous in gain: passing 100% doesn't step the output.
        let at = RenderKernel.amplify(0.98, gain: 1, limit: RenderKernel.limiterWeight(gain: 1))
        let above = RenderKernel.amplify(0.98, gain: 1.0001, limit: RenderKernel.limiterWeight(gain: 1.0001))
        #expect(abs(at - above) < 0.001)
    }

    @Test func monoOutputGetsADownmix() {
        // AirPods in a call (HFP) and mono speakerphones have one output channel.
        let input = TestBufferList(channels: [2], frames: 8) { _, _, c in c == 0 ? 0.2 : 0.4 }
        let output = TestBufferList(channels: [1], frames: 8)
        var state = openState()
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1)
        #expect(abs(output.sample(buffer: 0, frame: 7, channel: 0) - 0.3) < 0.0001)
    }

    @Test func duplexDeviceWithTwoOutputStreamsPlaysToTheMainOutputs() {
        // Inputs: the device microphone, then the tap. Outputs: main and headphone streams.
        let input = TestBufferList(channels: [1, 2], frames: 8) { b, _, c in b == 0 ? 0.9 : (c == 0 ? 0.4 : 0.2) }
        let output = TestBufferList(channels: [2, 2], frames: 8)
        var state = openState()
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1)
        #expect(output.sample(buffer: 0, frame: 7, channel: 0) == 0.4)
        #expect(output.sample(buffer: 0, frame: 7, channel: 1) == 0.2)
        #expect(output.peak(buffer: 1) == 0)
    }

    @Test func preferredPairInTheSecondStream() {
        let input = TestBufferList(channels: [2], frames: 8) { _, _, c in c == 0 ? 0.1 : 0.2 }
        let output = TestBufferList(channels: [2, 2], frames: 8)
        var state = openState()
        state.stereoLeft = 2
        state.stereoRight = 3
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1)
        #expect(output.peak(buffer: 0) == 0)
        #expect(output.sample(buffer: 1, frame: 7, channel: 0) == 0.1)
        #expect(output.sample(buffer: 1, frame: 7, channel: 1) == 0.2)
    }

    @Test func multichannelRestTapIsCopied() {
        let input = TestBufferList(channels: [4], frames: 8) { _, _, c in Float(c + 1) / 10 }
        let output = TestBufferList(channels: [4], frames: 8)
        var state = openState()
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 1)
        for c in 0..<4 { #expect(output.sample(buffer: 0, frame: 3, channel: c) == Float(c + 1) / 10) }
    }

    @Test func convergedRampSnapsToTheExactTarget() {
        let input = TestBufferList(channels: [2], frames: 48_000) { _, _, _ in 0.5 }
        let output = TestBufferList(channels: [2], frames: 48_000)
        var state = openState(gain: 1)
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 0.5)
        #expect(state.gain == 0.5)
        var muted = openState(gain: 1)
        _ = RenderKernel.render(input: input.list, output: output.list, state: &muted, target: 0)
        #expect(muted.gain == 0)
        var boosted = openState(gain: 1)
        _ = RenderKernel.render(input: input.list, output: output.list, state: &boosted, target: 2)
        #expect(boosted.gain == 2)
    }

    @Test func steadyPathMatchesThePerFramePath() {
        // A flat schedule forces the per-frame path at the same constant gain.
        let layouts: [(input: [Int], output: [Int], left: Int, right: Int)] = [
            ([2], [2], 0, 1), ([1], [2], 0, 1), ([2], [4], 2, 3), ([2], [1], 0, 1), ([4], [4], 0, 1), ([1, 2], [2], 0, 1),
        ]
        for layout in layouts {
            for gain: Float in [0.5, 1.5] {
                let input = TestBufferList(channels: layout.input, frames: 64) { b, f, c in sin(Float(f * 7 + c * 3 + b)) * 0.9 }
                let steady = TestBufferList(channels: layout.output, frames: 64)
                let perFrame = TestBufferList(channels: layout.output, frames: 64)
                var a = openState(gain: gain)
                a.stereoLeft = layout.left
                a.stereoRight = layout.right
                var b = a
                let ra = RenderKernel.render(input: input.list, output: steady.list, state: &a, target: gain)
                let flat = RampSchedule(from: gain, to: gain, startHost: 0, durationTicks: 1_000_000)
                let rb = RenderKernel.render(input: input.list, output: perFrame.list, state: &b, target: gain, schedule: flat)
                #expect(steady.samples == perFrame.samples)
                #expect(ra.peakIn == rb.peakIn)
            }
        }
    }

    @Test func rampScheduleEnds() {
        let ramp = RampSchedule(from: 0, to: 1, startHost: 1000, durationTicks: 100)
        #expect(!ramp.hasEnded(atHost: 500))
        #expect(!ramp.hasEnded(atHost: 1099))
        #expect(ramp.hasEnded(atHost: 1100))
        #expect(RampSchedule(from: 0, to: 1, startHost: 1000, durationTicks: 0).hasEnded(atHost: 0))
    }

    @Test func resumeGapScalesWithBufferSize() {
        #expect(RenderKernel.isResume(previousHost: 0, nowHost: 5, frames: 512, ticksPerFrame: 1, minimumGapTicks: 100))
        // Small buffers: the minimum gap decides.
        #expect(RenderKernel.isResume(previousHost: 1000, nowHost: 1200, frames: 10, ticksPerFrame: 1, minimumGapTicks: 100))
        #expect(!RenderKernel.isResume(previousHost: 1000, nowHost: 1050, frames: 10, ticksPerFrame: 1, minimumGapTicks: 100))
        // Large buffers: a gap of one or two buffers is normal.
        #expect(!RenderKernel.isResume(previousHost: 1000, nowHost: 2000, frames: 512, ticksPerFrame: 1, minimumGapTicks: 100))
        #expect(RenderKernel.isResume(previousHost: 1000, nowHost: 3000, frames: 512, ticksPerFrame: 1, minimumGapTicks: 100))
    }

    @Test func zeroSampleRateCountsAs48kHz() {
        var state = KernelState()
        state.configure(sampleRate: 0, ticksPerSecond: 48_000)
        #expect(state.ticksPerFrame == 1)
        #expect(state.gateFadeFrames == 1920)
        #expect(state.rampCoefficient.isFinite)
    }

    @Test func softLimitIsContinuousAndMonotonic() {
        #expect(RenderKernel.softLimit(0.5) == 0.5)
        #expect(abs(RenderKernel.softLimit(0.9001) - 0.9001) < 0.0001)
        var previous: Float = 0
        for step in 0...400 {
            let x = Float(step) / 100
            let y = RenderKernel.softLimit(x)
            #expect(y >= previous)
            #expect(y <= 1)
            previous = y
        }
        #expect(RenderKernel.softLimit(-3) == -RenderKernel.softLimit(3))
    }

    @Test func scheduledRampIsLinearInHostTime() {
        let input = TestBufferList(channels: [2], frames: 101) { _, _, _ in 1 }
        let output = TestBufferList(channels: [2], frames: 101)
        var state = openState(gain: 0)
        state.ticksPerFrame = 1
        let schedule = RampSchedule(from: 0, to: 0.8, startHost: 1000, durationTicks: 100)
        _ = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 0, schedule: schedule, outputHostTime: 1000)
        #expect(abs(output.sample(buffer: 0, frame: 50, channel: 0) - 0.4) < 0.0001)
        #expect(abs(output.sample(buffer: 0, frame: 100, channel: 0) - 0.8) < 0.0001)
        #expect(state.gain == 0.8)
    }
}

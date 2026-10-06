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
        let result = RenderKernel.render(input: input.list, output: output.list, state: &state, target: 2)
        #expect(result.peakOut <= 1)
        #expect(result.peakOut > 0.9)
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

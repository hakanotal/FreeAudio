import Testing
@testable import FreeAudioCore

struct VolumeCurveTests {
    @Test func endpointsAreFixed() {
        #expect(VolumeCurve.gain(forSlider: 0) == 0)
        #expect(VolumeCurve.gain(forSlider: 1) == 1)
    }

    @Test func halfwayIsAboutMinus12dB() {
        #expect(VolumeCurve.gain(forSlider: 0.5) == 0.25)
    }

    @Test func outOfRangeInputIsClamped() {
        #expect(VolumeCurve.gain(forSlider: -0.2) == 0)
        #expect(VolumeCurve.gain(forSlider: 1.5) == 1)
        #expect(VolumeCurve.slider(forGain: 4) == 1)
    }

    @Test(arguments: [0.0, 0.1, 0.33, 0.5, 0.9, 1.0])
    func roundTrips(position: Double) {
        let back = VolumeCurve.slider(forGain: VolumeCurve.gain(forSlider: position))
        #expect(abs(back - position) < 1e-12)
    }
}

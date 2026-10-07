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

    @Test func appCurveIsContinuousAtOneHundredPercent() {
        #expect(VolumeCurve.appGain(forPercent: 0) == 0)
        #expect(VolumeCurve.appGain(forPercent: 50) == 0.25)
        #expect(VolumeCurve.appGain(forPercent: 100) == 1)
        #expect(abs(VolumeCurve.appGain(forPercent: 100.01) - 1) < 0.001)
        #expect(VolumeCurve.appGain(forPercent: 150) == 1.5)
        #expect(VolumeCurve.appGain(forPercent: 250) == 2)
    }

    @Test(arguments: [0.0, 12.5, 50, 99, 100, 101, 175, 200])
    func appCurveRoundTrips(percent: Double) {
        let back = VolumeCurve.appPercent(forGain: VolumeCurve.appGain(forPercent: percent))
        #expect(abs(back - percent) < 1e-9)
    }

    @Test func detentsSnapOnlyNearby() {
        let range = 0.0...200
        #expect(SliderDetents.values(step: 25, in: 0...100) == [0, 25, 50, 75, 100])
        #expect(SliderDetents.values(step: 25, in: range).count == 9)
        #expect(SliderDetents.snap(97, step: 25, in: range, zone: 5) == 100)
        #expect(SliderDetents.snap(104, step: 25, in: range, zone: 5) == 100)
        #expect(SliderDetents.snap(88, step: 25, in: range, zone: 5) == 88)
        #expect(SliderDetents.snap(2, step: 25, in: range, zone: 5) == 0)
        #expect(SliderDetents.snap(-3, step: 25, in: range, zone: 5) == 0)
        #expect(SliderDetents.snap(210, step: 25, in: range, zone: 5) == 200)
    }

    @Test(arguments: [0.0, 0.1, 0.33, 0.5, 0.9, 1.0])
    func roundTrips(position: Double) {
        let back = VolumeCurve.slider(forGain: VolumeCurve.gain(forSlider: position))
        #expect(abs(back - position) < 1e-12)
    }
}

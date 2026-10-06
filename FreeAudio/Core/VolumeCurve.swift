import Foundation

/// Maps volume slider positions (0–1) to linear gain and back.
///
/// App sliders and software device volume use a square law, so the slider feels even to the
/// ear (50% ≈ -12 dB). Hardware device sliders do not use this: the driver's volume scalar is
/// already tapered, and squaring it again makes the bottom of the slider useless.
enum VolumeCurve {
    /// Linear gain for a slider position.
    static func gain(forSlider position: Double) -> Double {
        let p = min(max(position, 0), 1)
        return p * p
    }

    /// Slider position for a linear gain (the inverse of `gain(forSlider:)`).
    static func slider(forGain gain: Double) -> Double {
        sqrt(min(max(gain, 0), 1))
    }
}

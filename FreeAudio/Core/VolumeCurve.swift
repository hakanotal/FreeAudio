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

    /// Highest app level in percent (100% in the middle of the app slider).
    static let maxAppPercent: Double = 200

    /// Gain for an app level in percent (0–200). Up to 100% the same even-feeling curve as the
    /// other sliders; above 100% straight amplification, so 200% doubles the amplitude (+6 dB).
    static func appGain(forPercent percent: Double) -> Double {
        let p = min(max(percent, 0), maxAppPercent)
        return p <= 100 ? gain(forSlider: p / 100) : p / 100
    }

    /// App level in percent for a gain (the inverse of `appGain(forPercent:)`).
    static func appPercent(forGain gain: Double) -> Double {
        let g = min(max(gain, 0), maxAppPercent / 100)
        return g <= 1 ? slider(forGain: g) * 100 : g * 100
    }
}

/// Snap points ("detents") for volume sliders: values close to a multiple of `step` jump to it,
/// so 0, 25, 50, 75 and 100% are easy to hit.
enum SliderDetents {
    /// The detent values inside `range`.
    static func values(step: Double, in range: ClosedRange<Double>) -> [Double] {
        guard step > 0 else { return [] }
        return stride(from: range.lowerBound, through: range.upperBound + step / 1000, by: step).map { min($0, range.upperBound) }
    }

    /// `value` moved to the nearest detent when it is within `zone` of it, else unchanged.
    static func snap(_ value: Double, step: Double, in range: ClosedRange<Double>, zone: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard step > 0, zone > 0 else { return clamped }
        let nearest = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
        let detent = min(max(nearest, range.lowerBound), range.upperBound)
        return abs(clamped - detent) <= zone ? detent : clamped
    }
}

import AppKit
import SwiftUI

/// Volume slider in percent with tick marks and snap points every 25%: values close to 0, 25,
/// 50, 75, 100 … jump to them, with a haptic click on Force Touch trackpads. App sliders run
/// 0–200 with the fill starting at 100 (`neutralValue`); device sliders run 0–100.
struct VolumeSlider: View {
    @Binding var percent: Double
    var range: ClosedRange<Double> = 0...100
    var neutralValue: Double? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var snappedTo: Double?

    private static let step: Double = 25

    /// Snap zone on either side of a detent: 2.5% of the slider's travel, so it feels the same
    /// on a 0–100 and a 0–200 slider.
    private var zone: Double { (range.upperBound - range.lowerBound) * 0.025 }

    var body: some View {
        Slider(
            value: Binding(get: { percent }, set: { update($0) }),
            in: range,
            neutralValue: neutralValue,
            label: { EmptyView() },
            ticks: {
                SliderTickContentForEach(SliderDetents.values(step: Self.step, in: range), id: \.self) { value in
                    SliderTick(value)
                }
            },
            onEditingChanged: onEditingChanged
        )
        .labelsHidden()
    }

    private func update(_ raw: Double) {
        let value = SliderDetents.snap(raw, step: Self.step, in: range, zone: zone)
        let detent: Double? = value != raw ? value : nil
        if let detent, detent != snappedTo {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        snappedTo = detent
        percent = value
    }
}

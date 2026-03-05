#if os(iOS) || os(macOS)
import simd
import SwiftUI

// MARK: - Culling Sections

struct NormalizedCullingSection: View {
    @Binding var enabled: Bool
    @Binding var minBounds: SIMD3<Float>
    @Binding var maxBounds: SIMD3<Float>
    var disabled: Bool = false

    var body: some View {
        Section("Culling Bounding Box") {
            Toggle("Enable Culling", isOn: $enabled)
                .disabled(disabled)

            if enabled {
                NormalizedBoundsSlider(label: "Min X", value: $minBounds.x)
                NormalizedBoundsSlider(label: "Min Y", value: $minBounds.y)
                NormalizedBoundsSlider(label: "Min Z", value: $minBounds.z)
                NormalizedBoundsSlider(label: "Max X", value: $maxBounds.x)
                NormalizedBoundsSlider(label: "Max Y", value: $maxBounds.y)
                NormalizedBoundsSlider(label: "Max Z", value: $maxBounds.z)
            }
        }
    }
}

struct AbsoluteCullingSection: View {
    @Binding var enabled: Bool
    @Binding var minBounds: SIMD3<Float>
    @Binding var maxBounds: SIMD3<Float>
    var range: ClosedRange<Float> = -20...20

    var body: some View {
        Section("Culling Bounding Box") {
            Toggle("Enable Culling", isOn: $enabled)

            if enabled {
                AbsoluteBoundsSlider(label: "Min X", value: $minBounds.x, range: range)
                AbsoluteBoundsSlider(label: "Min Y", value: $minBounds.y, range: range)
                AbsoluteBoundsSlider(label: "Min Z", value: $minBounds.z, range: range)
                AbsoluteBoundsSlider(label: "Max X", value: $maxBounds.x, range: range)
                AbsoluteBoundsSlider(label: "Max Y", value: $maxBounds.y, range: range)
                AbsoluteBoundsSlider(label: "Max Z", value: $maxBounds.z, range: range)
            }
        }
    }
}

// MARK: - Bounds Sliders

struct NormalizedBoundsSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text((value * 100).formatted(.number.precision(.fractionLength(0))) + "%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0...1)
        }
    }
}

struct AbsoluteBoundsSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(2))))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Time Since Sort View

struct TimeSinceSortView: View {
    let sortTime: Date

    @State private var timeSince: TimeInterval = 0

    var body: some View {
        Text(formatTimeSince(timeSince))
            .monospacedDigit()
            .task(id: sortTime) {
                while !Task.isCancelled {
                    timeSince = Date().timeIntervalSince(sortTime)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
    }

    private func formatTimeSince(_ interval: TimeInterval) -> String {
        if interval < 1 {
            return (interval * 1_000).formatted(.number.precision(.fractionLength(0))) + " ms"
        }
        if interval < 60 {
            return interval.formatted(.number.precision(.fractionLength(1))) + " s"
        }
        return interval.formatted(.number.precision(.fractionLength(0))) + " s"
    }
}
#endif

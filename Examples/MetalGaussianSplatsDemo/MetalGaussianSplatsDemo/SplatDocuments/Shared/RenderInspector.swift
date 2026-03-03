#if os(iOS) || os(macOS)
import MetalSprocketsGaussianSplats
import SwiftUI

struct RenderInspector<CullingContent: View>: View {
    @Binding var backgroundColor: Color
    @Binding var useSphericalHarmonics: Bool
    var sphericalHarmonicsDisabled: Bool = false
    var sphericalHarmonicsWarning: String?
    @Binding var showBoundingBoxes: Bool
    @Binding var debugModeEnabled: Bool
    @Binding var debugMode: SplatDebugMode
    var lastSortEvent: SortEvent?
    var onScreenshot: (() -> Void)?
    @ViewBuilder var cullingContent: () -> CullingContent

    @Environment(SplatViewModel.self) private var viewModel

    var body: some View {
        Section("Renderer") {
            LabeledContent("Type", value: "Spark")
            LabeledContent("FPS") {
                Text(viewModel.currentFPS.formatted(.number.precision(.fractionLength(1))))
                    .monospacedDigit()
            }
            ColorPicker("Background", selection: $backgroundColor)
            Toggle("Spherical Harmonics", isOn: $useSphericalHarmonics)
                .disabled(sphericalHarmonicsDisabled || debugModeEnabled)

            if let warning = sphericalHarmonicsWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Show Bounding Boxes", isOn: $showBoundingBoxes)
        }

        Section("Sorting") {
            Toggle("Enable Sorting", isOn: Binding(
                get: { viewModel.sortingEnabled },
                set: { viewModel.sortingEnabled = $0 }
            ))

            Button("Sort Now") {
                viewModel.triggerManualSort()
            }
            .disabled(viewModel.sortingEnabled)

            if let sortEvent = lastSortEvent {
                LabeledContent("Duration") {
                    Text((sortEvent.duration * 1_000).formatted(.number.precision(.fractionLength(2))) + " ms")
                        .monospacedDigit()
                }
                LabeledContent("Splats") {
                    Text(sortEvent.splatCount.formatted())
                        .monospacedDigit()
                }
                LabeledContent("Clouds") {
                    Text("\(sortEvent.cloudCount)")
                        .monospacedDigit()
                }
                LabeledContent("Time Since Sort") {
                    TimeSinceSortView(sortTime: sortEvent.time)
                }
            }
        }

        Section("Debug Visualization") {
            Toggle("Enable Debug Mode", isOn: $debugModeEnabled)

            if debugModeEnabled {
                Picker("Mode", selection: $debugMode) {
                    ForEach(SplatDebugMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text(debugMode.colorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        cullingContent()

        if let onScreenshot {
            Section("Export") {
                Button("Take Screenshot", systemImage: "camera") {
                    onScreenshot()
                }
            }
        }
    }
}
#endif

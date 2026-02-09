import simd
import SwiftUI

enum SplatRendererType: String, CaseIterable {
    case spark = "Spark"
    case stochastic = "Stochastic (Experimental)"
    case tileBased = "Tile Based (Experimental)"
    case antimatter15 = "Antimatter15 (Legacy)"
}

struct SplatDocumentRendererSettingsView: View {
    @Environment(SplatDocumentViewModel.self) private var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel

        Section("Renderer") {
            Picker("Type", selection: $viewModel.rendererType) {
                ForEach(SplatRendererType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            ColorPicker("Background", selection: $viewModel.backgroundColor)
            Toggle("Spherical Harmonics", isOn: $viewModel.useSphericalHarmonics)
                .disabled(!viewModel.hasSphericalHarmonicsData)
        }

        Section("Culling Bounding Box") {
            Toggle("Enable Culling", isOn: $viewModel.cullBoundingBoxEnabled)
                .disabled(viewModel.rendererType != .spark)

            if viewModel.cullBoundingBoxEnabled && viewModel.rendererType == .spark {
                CullBoundsSlider(label: "Min X", value: $viewModel.cullMinBounds.x)
                CullBoundsSlider(label: "Min Y", value: $viewModel.cullMinBounds.y)
                CullBoundsSlider(label: "Min Z", value: $viewModel.cullMinBounds.z)
                CullBoundsSlider(label: "Max X", value: $viewModel.cullMaxBounds.x)
                CullBoundsSlider(label: "Max Y", value: $viewModel.cullMaxBounds.y)
                CullBoundsSlider(label: "Max Z", value: $viewModel.cullMaxBounds.z)
            }

            if viewModel.rendererType != .spark {
                Text("Culling only available with Spark renderer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CullBoundsSlider: View {
    let label: String
    @Binding var value: Float
    var range: ClosedRange<Float> = -20...20

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}

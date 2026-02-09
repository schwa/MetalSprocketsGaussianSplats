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
                .disabled(viewModel.rendererType != .spark || viewModel.boundsSize == .zero)

            if viewModel.cullBoundingBoxEnabled, viewModel.rendererType == .spark {
                CullBoundsSlider(label: "Min X", value: $viewModel.cullMinNormalized.x)
                CullBoundsSlider(label: "Min Y", value: $viewModel.cullMinNormalized.y)
                CullBoundsSlider(label: "Min Z", value: $viewModel.cullMinNormalized.z)
                CullBoundsSlider(label: "Max X", value: $viewModel.cullMaxNormalized.x)
                CullBoundsSlider(label: "Max Y", value: $viewModel.cullMaxNormalized.y)
                CullBoundsSlider(label: "Max Z", value: $viewModel.cullMaxNormalized.z)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0...1)
        }
    }
}

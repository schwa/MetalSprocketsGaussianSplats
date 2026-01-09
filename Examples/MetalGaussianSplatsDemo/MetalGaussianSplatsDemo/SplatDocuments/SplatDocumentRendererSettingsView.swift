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
    }
}

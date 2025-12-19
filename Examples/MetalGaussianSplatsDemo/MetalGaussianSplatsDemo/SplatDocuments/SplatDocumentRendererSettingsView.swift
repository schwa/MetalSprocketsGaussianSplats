import SwiftUI

enum SplatRendererType: String, CaseIterable {
    case spark = "Spark"
    case antimatter15 = "Antimatter15"
    case stochastic = "Stochastic"
    case tileBased = "Tile Based"
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
        }
    }
}

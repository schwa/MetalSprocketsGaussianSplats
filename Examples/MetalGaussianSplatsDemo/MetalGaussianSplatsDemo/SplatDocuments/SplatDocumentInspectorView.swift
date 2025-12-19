import SwiftUI

struct SplatDocumentInspectorView: View {
    enum Mode: String, CaseIterable {
        case info = "Info"
        case renderer = "Renderer"
    }

    @State private var mode: Mode = .info

    var body: some View {
        Form {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .info:
                SplatDocumentInfoView()
            case .renderer:
                SplatDocumentRendererSettingsView()
            }
        }
        .inspectorColumnWidth(min: 200, ideal: 300, max: 400)
    }
}

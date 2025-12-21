import SwiftUI

struct SplatDocumentInspectorView: View {
    @Binding var tab: InspectorTab

    var body: some View {
        Form {
            Picker("Tab", selection: $tab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .info:
                SplatDocumentInfoView()
            case .render:
                SplatDocumentRendererSettingsView()
            case .camera:
                SplatDocumentCameraView()
            }
        }
        #if !os(visionOS)
        .inspectorColumnWidth(min: 200, ideal: 300, max: 400)
        #endif
    }
}

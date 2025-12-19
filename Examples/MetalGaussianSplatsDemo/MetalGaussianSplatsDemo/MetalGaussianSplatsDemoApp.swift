import SwiftUI
import UniformTypeIdentifiers

@main
struct MetalGaussianSplatsDemoApp: App {
    var body: some Scene {
        DocumentGroup(viewing: SplatDocument.self) { file in
            SplatDocumentView(document: file.document, fileURL: file.fileURL)
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

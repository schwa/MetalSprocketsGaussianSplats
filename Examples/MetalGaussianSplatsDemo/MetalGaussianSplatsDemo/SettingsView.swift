import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        form
            #if !os(macOS)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        #endif
    }

    private var form: some View {
        Form {
            #if !os(macOS)
            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
            }
            #endif
            Section("Image to Gaussian Splat Conversion") {
                Text("Sharp is an Apple ML model that converts images to Gaussian Splats.")
                Link("apple/ml-sharp on GitHub", destination: URL(string: "https://github.com/apple/ml-sharp")!)
                ModelDownloadView(
                    modelName: "SharpPredictor",
                    downloadURL: URL(string: "https://huggingface.co/jwight/spark/resolve/main/SharpPredictor.mlmodelc.zip")!,
                    destinationDirectory: SharpModelManager.modelDirectory
                )
            }

            Section("Sample Splats") {
                Text("Sample Gaussian Splat files from the Spark project, including food scans, animals, and scenes.")
                Link("sparkjs.dev", destination: URL(string: "https://sparkjs.dev")!)
                SampleAssetsDownloadView()
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 200)
        #endif
    }
}

enum SharpModelManager {
    static var modelDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SharpModel")
    }

    static var modelURL: URL {
        modelDirectory.appendingPathComponent("SharpPredictor.mlmodelc")
    }

    static var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }
}

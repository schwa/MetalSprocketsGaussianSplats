import SwiftUI
#if os(macOS)
import AppKit
#endif

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
            #if os(macOS)
            Section("Application") {
                Button("Reveal Application Support Folder", systemImage: "folder") {
                    revealAppSupport()
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
        .frame(minWidth: 400, minHeight: 480)
        #endif
    }

    #if os(macOS)
    private func revealAppSupport() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let containerURL = appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([containerURL])
    }
    #endif
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

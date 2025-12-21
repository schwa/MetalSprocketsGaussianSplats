#if os(macOS)
import AppKit
#endif
import Sharp
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var errorMessage: String?

    private var modelDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SharpModel")
    }

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
                        .navigationTitle("About")
                } label: {
                    Label("About", systemImage: "info.circle")
                }
            }
            #endif
            Section("Image to Gaussian Splat Conversion") {
                Text("Sharp is an Apple ML model that converts images to Gaussian Splats.")
                Link("apple/ml-sharp on GitHub", destination: URL(string: "https://github.com/apple/ml-sharp")!)
                if let modelURL = Sharp.cachedModel(in: modelDirectory) {
                    HStack {
                        #if os(macOS)
                        Button("Reveal") {
                            NSWorkspace.shared.selectFile(modelURL.path, inFileViewerRootedAtPath: modelDirectory.path)
                        }
                        #endif
                        Label("Model Downloaded", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Delete", role: .destructive) {
                            try? FileManager.default.removeItem(at: modelDirectory)
                        }
                    }
                } else if isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: downloadProgress) {
                            Text("Downloading Sharp Model…")
                        }
                        Text("\(Int(downloadProgress * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sharp converts images to Gaussian Splats. The model needs to be downloaded before use.")
                            .foregroundStyle(.secondary)
                        Button("Download Model") {
                            Task {
                                await downloadModel()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 200)
        #endif
    }

    private func downloadModel() async {
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            _ = try await Sharp.download(to: modelDirectory) { progress in
                Task { @MainActor in
                    downloadProgress = progress
                }
            }
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }

        isDownloading = false
    }
}

#if os(iOS) || (os(macOS) && !arch(x86_64))
import MetalSprocketsGaussianSplats
import SwiftUI
import UniformTypeIdentifiers

struct SplatSidebarView: View {
    @Binding var splatURL: URL?
    @Binding var folderURL: URL?
    @Binding var folderSplatFiles: [URL]
    @Binding var folderBookmarkData: Data?

    @State private var showingFolderPicker = false
    @State private var showingImporter = false
    @State private var showingDownloadPicker = false
    @State private var downloadProgress: String?
    @State private var isDownloading = false

    var body: some View {
        List(selection: $splatURL) {
            Section {
                Button("Choose Splat File...") {
                    showingImporter = true
                }
                .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.antimatter15Splat, .spz, .ply, .json]) { result in
                    if case .success(let url) = result {
                        splatURL = url
                    }
                }

                Button("Choose Splats Folder...") {
                    showingFolderPicker = true
                }
                .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result {
                        folderURL = url
                        folderBookmarkData = url.path.data(using: .utf8)
                        scanFolder(url)
                    }
                }
            }

            Section("Download") {
                Button("Download Samples...") {
                    showingDownloadPicker = true
                }
                .disabled(isDownloading)
                .fileImporter(isPresented: $showingDownloadPicker, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result {
                        folderURL = url
                        folderBookmarkData = url.path.data(using: .utf8)
                        Task {
                            await downloadSparkAssets(to: url)
                        }
                    }
                }
                if let downloadProgress {
                    Text(downloadProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Bundled") {
                Text("Last Chance")
                    .tag(Bundle.main.url(forResource: "centered_lastchance", withExtension: "splat"))
                Text("Train")
                    .tag(Bundle.main.url(forResource: "train", withExtension: "splat"))
            }

            if !folderSplatFiles.isEmpty {
                Section(folderURL?.lastPathComponent ?? "Folder") {
                    ForEach(folderSplatFiles, id: \.self) { file in
                        Text(file.lastPathComponent)
                            .tag(file as URL?)
                    }
                }
            }
        }
        .navigationTitle("Splats")
    }

    private func scanFolder(_ url: URL) {
        let fileManager = FileManager.default
        let extensions = ["ply", "splat", "spz"]

        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            folderSplatFiles = contents.filter { file in
                extensions.contains(file.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            fatalError("Failed to scan folder: \(error)")
        }
    }

    @MainActor
    private func downloadSparkAssets(to destinationURL: URL) async {
        // Security scope already started by caller

        isDownloading = true

        // Fetch assets.json
        let assetsURL = URL(string: "https://raw.githubusercontent.com/sparkjsdev/spark/main/examples/assets.json")!

        do {
            let (data, _) = try await URLSession.shared.data(from: assetsURL)
            let assets = try JSONDecoder().decode([String: AssetInfo].self, from: data)

            // Filter for splat files only
            let splatAssets = assets.filter { $0.key.hasSuffix(".spz") }
            let total = splatAssets.count
            var completed = 0

            for (filename, info) in splatAssets {
                downloadProgress = "Downloading \(completed + 1)/\(total): \(filename)"

                guard let url = URL(string: info.url) else { continue }

                let (fileData, _) = try await URLSession.shared.data(from: url)
                let fileURL = destinationURL.appendingPathComponent(filename)
                try fileData.write(to: fileURL)

                completed += 1
            }

            downloadProgress = "Downloaded \(completed) files"
            isDownloading = false
            scanFolder(destinationURL)
        } catch {
            downloadProgress = "Download failed: \(error.localizedDescription)"
            isDownloading = false
        }
    }

    struct AssetInfo: Codable {
        let url: String
        let directory: String
    }
}

#endif

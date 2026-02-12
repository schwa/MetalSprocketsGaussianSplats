import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct SampleAssetsDownloadView: View {
    @State private var state: DownloadState = .idle
    @State private var showFolderPicker = false
    @State private var downloadTask: URLSessionDownloadTask?

    private let assetsURL = URL(string: "https://raw.githubusercontent.com/sparkjsdev/spark/main/examples/assets.json")!

    enum DownloadState: Equatable {
        case idle
        case fetchingManifest
        case downloading(current: String, index: Int, total: Int, progress: Double)
        case completed(count: Int)
        case error(String)
    }

    struct AssetInfo: Decodable {
        let url: String
        let directory: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .idle:
                Button("Download Sample Splats…") {
                    showFolderPicker = true
                }
                .buttonStyle(.borderedProminent)

            case .fetchingManifest:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching asset list…")
                }

            case let .downloading(current, index, total, progress):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloading \(index + 1) of \(total): \(current)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ProgressView(value: Double(index) + progress, total: Double(total)) {
                        Text("Downloading…")
                    }

                    HStack {
                        Text("\(Int((Double(index) + progress) / Double(total) * 100))%")
                            .monospacedDigit()
                        Spacer()
                        Button("Cancel", role: .destructive) {
                            cancelDownload()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .font(.caption)
                }

            case let .completed(count):
                HStack {
                    Label("Downloaded \(count) splat files", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Download More…") {
                        showFolderPicker = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

            case let .error(message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Try Again") {
                        showFolderPicker = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .fileExporter(
            isPresented: $showFolderPicker,
            document: FolderPickerDocument(),
            contentType: .folder,
            defaultFilename: "Sample Splats"
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    await downloadAssets(to: url)
                }
            case .failure(let error):
                state = .error(error.localizedDescription)
            }
        }
    }

    private func downloadAssets(to destinationFolder: URL) async {
        state = .fetchingManifest

        do {
            // Fetch and parse assets.json
            let (data, _) = try await URLSession.shared.data(from: assetsURL)
            let allAssets = try JSONDecoder().decode([String: AssetInfo].self, from: data)

            // Filter to only .spz files
            let splatAssets = allAssets.filter { $0.key.hasSuffix(".spz") }
            let sortedAssets = splatAssets.sorted { $0.key < $1.key }

            guard !sortedAssets.isEmpty else {
                state = .error("No splat files found in manifest")
                return
            }

            // Download each asset
            for (index, (filename, asset)) in sortedAssets.enumerated() {
                state = .downloading(current: filename, index: index, total: sortedAssets.count, progress: 0)

                // Create subdirectory
                let subdirectory = destinationFolder.appendingPathComponent(asset.directory)
                try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

                // Download file
                guard let url = URL(string: asset.url) else { continue }
                let destinationURL = subdirectory.appendingPathComponent(filename)

                // Skip if already exists
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    continue
                }

                let (tempURL, _) = try await downloadWithProgress(from: url, index: index, total: sortedAssets.count)
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            }

            state = .completed(count: sortedAssets.count)

            #if os(macOS)
            // Reveal in Finder
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: destinationFolder.path)
            #endif
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func downloadWithProgress(from url: URL, index: Int, total: Int) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadProgressDelegate { progress in
                Task { @MainActor in
                    state = .downloading(
                        current: url.lastPathComponent,
                        index: index,
                        total: total,
                        progress: progress
                    )
                }
            } completion: { result in
                continuation.resume(with: result)
            }

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            downloadTask = task
            task.resume()
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }
}

// MARK: - Folder Picker Document

private struct FolderPickerDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }

    init() {
        // Empty folder document for folder picker
    }

    init(configuration _: ReadConfiguration) throws {
        // Not used for folder creation
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(directoryWithFileWrappers: [:])
    }
}

// MARK: - Download Delegate

private class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double) -> Void
    let completionHandler: (Result<(URL, URLResponse), Error>) -> Void

    init(
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<(URL, URLResponse), Error>) -> Void
    ) {
        self.progressHandler = progress
        self.completionHandler = completion
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        progressHandler(progress)
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tempURL)
            if let response = downloadTask.response {
                completionHandler(.success((tempURL, response)))
            } else {
                completionHandler(.failure(NSError(domain: "SampleAssets", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response"])))
            }
        } catch {
            completionHandler(.failure(error))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completionHandler(.failure(error))
        } else {
            // Successful completion is handled by urlSession(_:downloadTask:didFinishDownloadingTo:)
        }
    }
}

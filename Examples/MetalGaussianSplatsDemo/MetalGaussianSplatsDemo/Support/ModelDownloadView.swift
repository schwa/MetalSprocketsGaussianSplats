import SwiftUI
import ZIPFoundation
#if os(macOS)
import AppKit
#endif

struct ModelDownloadView: View {
    let modelName: String
    let downloadURL: URL
    let destinationDirectory: URL

    @State private var state: DownloadState = .checking
    @State private var downloadTask: URLSessionDownloadTask?

    private var modelURL: URL {
        destinationDirectory.appendingPathComponent("\(modelName).mlmodelc")
    }

    private var zipURL: URL {
        destinationDirectory.appendingPathComponent("\(modelName).mlmodelc.zip")
    }

    enum DownloadState: Equatable {
        case checking
        case notDownloaded
        case downloading(progress: Double, bytesWritten: Int64, totalBytes: Int64)
        case downloaded
        case error(String)
    }

    var body: some View {
        Group {
            switch state {
            case .checking:
                ProgressView()
                    .controlSize(.small)

            case .notDownloaded:
                Button("Download Model") {
                    Task {
                        await download()
                    }
                }
                .buttonStyle(.borderedProminent)

            case let .downloading(progress, bytesWritten, totalBytes):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress) {
                        Text("Downloading…")
                    }
                    HStack {
                        Text("\(Int(progress * 100))%")
                            .monospacedDigit()
                        Spacer()
                        Text("\(formatBytes(bytesWritten)) / \(formatBytes(totalBytes))")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Cancel", role: .destructive) {
                        cancelDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

            case .downloaded:
                HStack {
                    Label("Model Downloaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    #if os(macOS)
                    Button("Reveal") {
                        NSWorkspace.shared.selectFile(modelURL.path, inFileViewerRootedAtPath: destinationDirectory.path)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    #endif
                    Button("Delete", role: .destructive) {
                        deleteModel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

            case .error(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Try Again") {
                        Task {
                            await download()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .task {
            checkModelExists()
        }
    }

    private func checkModelExists() {
        if FileManager.default.fileExists(atPath: modelURL.path) {
            state = .downloaded
        } else {
            state = .notDownloaded
        }
    }

    private func download() async {
        state = .downloading(progress: 0, bytesWritten: 0, totalBytes: 0)

        do {
            // Create destination directory
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

            // Download with progress
            let (localURL, _) = try await downloadWithProgress(from: downloadURL)

            // Extract
            try await extract(zipURL: localURL, to: destinationDirectory)

            // Clean up zip file
            try? FileManager.default.removeItem(at: localURL)

            // Verify
            if FileManager.default.fileExists(atPath: modelURL.path) {
                state = .downloaded
            } else {
                state = .error("Model file not found after extraction")
            }
        } catch is CancellationError {
            state = .notDownloaded
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func downloadWithProgress(from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate { _, totalBytesWritten, totalBytesExpectedToWrite in
                let progress = totalBytesExpectedToWrite > 0
                    ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                    : 0
                Task { @MainActor in
                    state = .downloading(
                        progress: progress,
                        bytesWritten: totalBytesWritten,
                        totalBytes: totalBytesExpectedToWrite
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

    private func extract(zipURL: URL, to directory: URL) async throws {
        let targetRoot = "\(modelName).mlmodelc"
        try await Task.detached {
            let archive = try Archive(url: zipURL, accessMode: .read)

            // Remove any existing model directory before extraction to prevent conflicts
            let targetURL = directory.appendingPathComponent(targetRoot, isDirectory: true)
            try? FileManager.default.removeItem(at: targetURL)

            for entry in archive {
                let path = entry.path

                // Skip macOS metadata entries
                if path.hasPrefix("__MACOSX/") || path.contains("/.DS_Store") { continue }

                // Only extract the desired model directory
                let components = path.split(separator: "/", omittingEmptySubsequences: true)
                guard let firstComponent = components.first, firstComponent == Substring(targetRoot) else { continue }

                let relativePath = components.dropFirst().joined(separator: "/")
                let destinationURL: URL
                if relativePath.isEmpty {
                    destinationURL = targetURL
                } else {
                    destinationURL = targetURL.appendingPathComponent(relativePath)
                }

                let parentDirectory = destinationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

                _ = try archive.extract(entry, to: destinationURL)
            }
        }.value
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .notDownloaded
        // Clean up partial download
        try? FileManager.default.removeItem(at: zipURL)
    }

    private func deleteModel() {
        try? FileManager.default.removeItem(at: modelURL)
        checkModelExists()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Int64, Int64, Int64) -> Void
    let completionHandler: (Result<(URL, URLResponse), Error>) -> Void

    init(
        progress: @escaping (Int64, Int64, Int64) -> Void,
        completion: @escaping (Result<(URL, URLResponse), Error>) -> Void
    ) {
        self.progressHandler = progress
        self.completionHandler = completion
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move to a persistent location before the temp file is deleted
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        do {
            try FileManager.default.moveItem(at: location, to: tempURL)
            if let response = downloadTask.response {
                completionHandler(.success((tempURL, response)))
            } else {
                completionHandler(.failure(NSError(domain: "ModelDownload", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response"])))
            }
        } catch {
            completionHandler(.failure(error))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completionHandler(.failure(error))
        }
    }
}

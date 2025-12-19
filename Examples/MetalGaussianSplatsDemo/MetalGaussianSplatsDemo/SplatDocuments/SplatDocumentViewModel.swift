import CoreGraphics
import Foundation
import Observation
import Sharp
import SwiftUI
import UniformTypeIdentifiers

enum LoadingState: Equatable {
    case idle
    case loading
    case converting
    case ready
    case error(String)
}

@Observable
final class SplatDocumentViewModel {
    var descriptor: SplatCloudDescriptor?
    var viewSize: CGSize = .zero
    var rendererType: SplatRendererType = .spark
    var backgroundColor: Color = .black
    var loadingState: LoadingState = .idle
    var convertedURL: URL?

    private var sharp: Sharp?

    private var modelDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SharpModel")
    }

    func load(url: URL?, contentType: UTType?) async {
        guard let url else {
            descriptor = nil
            convertedURL = nil
            loadingState = .idle
            return
        }

        // Check if this is an image that needs conversion
        if let contentType, contentType.conforms(to: .image) {
            await convertImage(url: url)
        } else {
            loadingState = .loading
            descriptor = try? SplatCloudDescriptor(url: url)
            convertedURL = nil
            loadingState = descriptor != nil ? .ready : .error("Failed to load splat file")
        }
    }

    private func convertImage(url: URL) async {
        loadingState = .converting

        do {
            // Initialize Sharp if needed
            if sharp == nil {
                if let cachedModel = Sharp.cachedModel(in: modelDirectory) {
                    sharp = try Sharp(modelURL: cachedModel)
                } else {
                    // Download model
                    sharp = try await Sharp.download(to: modelDirectory) { _ in }
                }
            }

            guard let sharp else {
                loadingState = .error("Failed to initialize Sharp")
                return
            }

            // Create output directory
            let outputDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SharpOutput")
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let outputName = url.deletingPathExtension().lastPathComponent + ".ply"
            let outputURL = outputDir.appendingPathComponent(outputName)

            // Convert in background
            try await Task.detached {
                try sharp.convert(from: url, to: outputURL)
            }.value

            convertedURL = outputURL
            descriptor = try? SplatCloudDescriptor(url: outputURL)
            loadingState = .ready
        } catch {
            loadingState = .error("Conversion failed: \(error.localizedDescription)")
        }
    }
}

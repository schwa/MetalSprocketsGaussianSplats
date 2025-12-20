import CoreGraphics
import Foundation
import GeometryLite3D
import Observation
import Sharp
import simd
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

    // Camera
    enum CameraMode: String, CaseIterable {
        case object = "Object"
        case room = "Room"

        var initialPosition: SIMD3<Float> {
            switch self {
            case .object: [0, 0, 5]
            case .room: [0, 0, 0]
            }
        }
    }

    var cameraMode: CameraMode = .object {
        didSet { cameraMatrix = .init(translation: cameraMode.initialPosition) }
    }
    var cameraMatrix: simd_float4x4 = .init(translation: [0, 0, 5])
    var modelMatrix: simd_float4x4 = simd_float4x4(xRotation: .radians(.pi))
    var verticalAngleOfView: Double = 90

    // Model transform
    var modelRotationX: Float = .pi {
        didSet { updateModelMatrix() }
    }
    var modelRotationY: Float = 0 {
        didSet { updateModelMatrix() }
    }
    var modelRotationZ: Float = 0 {
        didSet { updateModelMatrix() }
    }
    var centerModel: Bool = false {
        didSet { updateModelMatrix() }
    }
    var boundsCenter: SIMD3<Float> = .zero

    private func updateModelMatrix() {
        let rotX = simd_float4x4(xRotation: .radians(modelRotationX))
        let rotY = simd_float4x4(yRotation: .radians(modelRotationY))
        let rotZ = simd_float4x4(zRotation: .radians(modelRotationZ))
        let rotation = rotZ * rotY * rotX
        if centerModel {
            let translation = simd_float4x4(translation: -boundsCenter)
            modelMatrix = rotation * translation
        } else {
            modelMatrix = rotation
        }
    }

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
            if let descriptor {
                if let bounds = try? await descriptor.computeBounds() {
                    boundsCenter = bounds.center
                }
                loadingState = .ready
            } else {
                loadingState = .error("Failed to load splat file")
            }
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
                    fatalError("TODO")
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
            if let descriptor, let bounds = try? await descriptor.computeBounds() {
                boundsCenter = bounds.center
            }
            loadingState = .ready
        } catch {
            loadingState = .error("Conversion failed: \(error.localizedDescription)")
        }
    }
}

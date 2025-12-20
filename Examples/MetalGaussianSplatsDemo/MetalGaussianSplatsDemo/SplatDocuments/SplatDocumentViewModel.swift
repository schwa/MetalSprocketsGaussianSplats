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
    var viewSize: CGSize = .zero {
        didSet { updateCameraForZoomToFit() }
    }
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
    var verticalAngleOfView: Double = 90 {
        didSet { updateCameraForZoomToFit() }
    }

    // Model transform
    var modelRotationX: Float = .pi {
        didSet {
            updateModelMatrix()
            updateCameraForZoomToFit()
        }
    }
    var modelRotationY: Float = 0 {
        didSet {
            updateModelMatrix()
            updateCameraForZoomToFit()
        }
    }
    var modelRotationZ: Float = 0 {
        didSet {
            updateModelMatrix()
            updateCameraForZoomToFit()
        }
    }
    var centerModel: Bool = false {
        didSet {
            updateModelMatrix()
            updateCameraForZoomToFit()
        }
    }
    var boundsCenter: SIMD3<Float> = .zero
    var boundsSize: SIMD3<Float> = .zero
    var zoomToFit: Bool = false {
        didSet {
            if zoomToFit {
                updateCameraForZoomToFit()
            } else {
                cameraMatrix = .init(translation: cameraMode.initialPosition)
            }
        }
    }

    private func updateCameraForZoomToFit() {
        guard zoomToFit, cameraMode == .object else { return }
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        guard boundsSize != .zero else { return }

        // Get the maximum extent of the bounding box (after rotation)
        let rotX = simd_float4x4(xRotation: .radians(modelRotationX))
        let rotY = simd_float4x4(yRotation: .radians(modelRotationY))
        let rotZ = simd_float4x4(zRotation: .radians(modelRotationZ))
        let rotation = rotZ * rotY * rotX

        // Transform the 8 corners of the bounding box and find the extents
        // Account for whether model is centered or not
        let center = centerModel ? SIMD3<Float>.zero : boundsCenter
        let halfSize = boundsSize / 2
        let corners: [SIMD3<Float>] = [
            center + [-halfSize.x, -halfSize.y, -halfSize.z],
            center + [halfSize.x, -halfSize.y, -halfSize.z],
            center + [-halfSize.x, halfSize.y, -halfSize.z],
            center + [halfSize.x, halfSize.y, -halfSize.z],
            center + [-halfSize.x, -halfSize.y, halfSize.z],
            center + [halfSize.x, -halfSize.y, halfSize.z],
            center + [-halfSize.x, halfSize.y, halfSize.z],
            center + [halfSize.x, halfSize.y, halfSize.z]
        ]

        var maxX: Float = 0
        var maxY: Float = 0
        var maxZ: Float = 0
        for corner in corners {
            let transformed = (rotation * SIMD4<Float>(corner, 1)).xyz
            maxX = max(maxX, abs(transformed.x))
            maxY = max(maxY, abs(transformed.y))
            maxZ = max(maxZ, abs(transformed.z))
        }

        let modelWidth = maxX * 2
        let modelHeight = maxY * 2
        let modelDepth = maxZ * 2

        // Calculate screen aspect ratio
        let screenAspect = Float(viewSize.width / viewSize.height)

        // Use the dimension that requires the greater distance
        let fovRadians = Float(verticalAngleOfView) * .pi / 180
        let halfFovTan = tan(fovRadians / 2)

        let distanceForHeight = (modelHeight / 2) / halfFovTan
        let distanceForWidth = (modelWidth / 2) / (halfFovTan * screenAspect)

        // Take the larger distance, add half the depth (camera from front of model), and add 10% margin
        let distance = (max(distanceForHeight, distanceForWidth) + modelDepth / 2) / 0.9

        // When not centered, offset camera to look at the transformed model center
        let modelCenter = centerModel ? SIMD3<Float>.zero : (rotation * SIMD4<Float>(boundsCenter, 1)).xyz
        cameraMatrix = .init(translation: [modelCenter.x, modelCenter.y, modelCenter.z + distance])
    }

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
                    boundsSize = bounds.size
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
                boundsSize = bounds.size
            }
            loadingState = .ready
        } catch {
            loadingState = .error("Conversion failed: \(error.localizedDescription)")
        }
    }
}

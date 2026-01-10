import Foundation
import GeometryLite3D
import simd
import UniformTypeIdentifiers

// MARK: - Transform

/// A transform stored as separate translation and rotation components
struct Transform: Codable, Sendable, Equatable {
    var translation: SIMD3<Float> = .zero
    var rotation: SIMD3<Float> = .zero  // Euler angles in radians (x, y, z)

    init(translation: SIMD3<Float> = .zero, rotation: SIMD3<Float> = .zero) {
        self.translation = translation
        self.rotation = rotation
    }

    /// Convert to a 4x4 matrix
    var matrix: simd_float4x4 {
        let rotX = simd_float4x4(xRotation: .radians(rotation.x))
        let rotY = simd_float4x4(yRotation: .radians(rotation.y))
        let rotZ = simd_float4x4(zRotation: .radians(rotation.z))
        let trans = simd_float4x4(translation: translation)
        return trans * rotZ * rotY * rotX
    }

    /// Create from a 4x4 matrix (decomposes it)
    init(matrix: simd_float4x4) {
        if let components = matrix.decompose {
            self.translation = components.translate
            let euler = Euler(components.rotation)
            self.rotation = SIMD3<Float>(euler.roll, euler.pitch, euler.yaw)
        } else {
            self.translation = .zero
            self.rotation = .zero
        }
    }

    static let identity = Transform()
}

// MARK: - SplatScene Model

/// A scene containing multiple splat clouds with their transforms
struct SplatScene: Codable, Sendable {
    var version: Int = 1
    var clouds: [CloudReference] = []
    var sceneTransform: Transform = Transform(rotation: [.pi, 0, 0])  // Default X rotation of 180°
    var camera: CameraState?
    var renderSettings: RenderSettings = RenderSettings()

    // Custom decoding to handle missing keys from older documents
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        clouds = try container.decodeIfPresent([CloudReference].self, forKey: .clouds) ?? []
        // Handle both old (matrix) and new (Transform) format
        if let transform = try? container.decodeIfPresent(Transform.self, forKey: .sceneTransform) {
            sceneTransform = transform
        } else if let matrix = try? container.decodeIfPresent(simd_float4x4.self, forKey: .sceneTransform) {
            sceneTransform = Transform(matrix: matrix)
        } else {
            sceneTransform = Transform(rotation: [.pi, 0, 0])
        }
        camera = try container.decodeIfPresent(CameraState.self, forKey: .camera)
        renderSettings = try container.decodeIfPresent(RenderSettings.self, forKey: .renderSettings) ?? RenderSettings()
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, clouds, sceneTransform, camera, renderSettings
    }

    struct CloudReference: Codable, Identifiable, Sendable, Equatable {
        var id: UUID = UUID()
        /// Security-scoped bookmark data for the splat file
        var bookmarkData: Data
        /// Per-cloud transform (applied before scene transform)
        var transform: Transform = .identity
        /// Whether this cloud should be rendered
        var enabled: Bool = true
        /// Display name (defaults to filename)
        var displayName: String?

        /// Resolve bookmark to URL
        /// - Returns: The resolved URL and whether the bookmark was stale
        func resolveURL() throws -> (url: URL, isStale: Bool) {
            var isStale = false
            #if os(macOS)
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #else
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif
            return (url, isStale)
        }

        /// Create a cloud reference from a URL
        init(url: URL, transform: Transform = .identity, displayName: String? = nil) throws {
            self.id = UUID()
            #if os(macOS)
            // Use minimalBookmark for files from fileImporter - withSecurityScope requires
            // the file to already be in the app's sandbox
            self.bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: [.nameKey],
                relativeTo: nil
            )
            #else
            self.bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: [.nameKey],
                relativeTo: nil
            )
            #endif
            self.transform = transform
            self.displayName = displayName ?? url.deletingPathExtension().lastPathComponent
        }

        // Codable with custom keys for transform
        enum CodingKeys: String, CodingKey {
            case id, bookmarkData, transform, enabled, displayName
        }
    }

    struct CameraState: Codable, Sendable {
        var matrix: simd_float4x4
        var verticalAngleOfView: Double

        init(matrix: simd_float4x4, verticalAngleOfView: Double) {
            self.matrix = matrix
            self.verticalAngleOfView = verticalAngleOfView
        }
    }

    struct RenderSettings: Codable, Sendable, Equatable {
        /// Whether to use spherical harmonics (only applies if all clouds have SH data)
        var useSphericalHarmonics: Bool = true
        /// Background color RGBA components (0-1 range)
        var backgroundColor: [Float] = [0, 0, 0, 1]
    }
}

// MARK: - simd_float4x4 Codable

extension simd_float4x4: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([Float].self)
        guard values.count == 16 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected 16 floats for simd_float4x4, got \(values.count)"
            )
        }
        self.init(
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let values: [Float] = [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w
        ]
        try container.encode(values)
    }
}

// MARK: - File Extension

extension UTType {
    static let splatScene = UTType(exportedAs: "com.schwa.splatscene", conformingTo: .json)
}

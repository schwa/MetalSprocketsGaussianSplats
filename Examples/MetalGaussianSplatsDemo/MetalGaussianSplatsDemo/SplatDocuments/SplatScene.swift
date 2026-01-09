import Foundation
import GeometryLite3D
import simd
import UniformTypeIdentifiers

// MARK: - SplatScene Model

/// A scene containing multiple splat clouds with their transforms
struct SplatScene: Codable, Sendable {
    var version: Int = 1
    var clouds: [CloudReference] = []
    var sceneTransform: simd_float4x4 = .identity
    var camera: CameraState?

    struct CloudReference: Codable, Identifiable, Sendable, Equatable {
        var id: UUID = UUID()
        /// Security-scoped bookmark data for the splat file
        var bookmarkData: Data
        /// Per-cloud transform (applied before scene transform)
        var transform: simd_float4x4 = .identity
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
        init(url: URL, transform: simd_float4x4 = .identity, displayName: String? = nil) throws {
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

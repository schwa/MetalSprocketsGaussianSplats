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

    static let identity = Self()

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case translation, rotation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translation = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .translation) ?? .zero
        rotation = try container.decode(RotationValue.self, forKey: .rotation).radians
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(translation, forKey: .translation)
        try container.encode(rotation, forKey: .rotation)
    }
}

// MARK: - Rotation Value (supports both radians and degrees)

/// A rotation value that can be decoded from either radians (floats) or degrees (strings like "45°")
/// Each component can be independently a float (radians) or string (degrees)
private struct RotationValue: Decodable {
    let radians: SIMD3<Float>

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()

        guard container.count == 3 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Rotation must have exactly 3 elements"
            )
        }

        var values: [Float] = []
        for _ in 0..<3 {
            // Try float first (radians)
            if let floatValue = try? container.decode(Float.self) {
                values.append(floatValue)
            }
            // Try string (degrees)
            else if let stringValue = try? container.decode(String.self) {
                values.append(try Self.parseAngle(stringValue))
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Rotation element must be a number (radians) or string like \"45°\" (degrees)"
                )
            }
        }

        radians = SIMD3<Float>(values[0], values[1], values[2])
    }

    /// Parse an angle string like "45°", "-90°", "180.5°"
    private static func parseAngle(_ string: String) throws -> Float {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Regex: optional minus, digits, optional decimal, required degree symbol
        let pattern = #"^(-?\d+\.?\d*)°$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let range = Range(match.range(at: 1), in: trimmed),
            let degrees = Float(String(trimmed[range]))
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid angle format: '\(string)'. Expected format like \"45°\""
                )
            )
        }

        return degrees * .pi / 180
    }
}

// MARK: - SplatScene Model

/// A scene containing multiple splat clouds with their transforms
struct SplatScene: Codable, Sendable {
    var version: Int = 1
    var clouds: [CloudReference] = []
    var sceneTransform = Transform(rotation: [.pi, 0, 0])  // Default X rotation of 180°
    var camera: CameraState?
    var renderSettings = RenderSettings()

    struct CloudReference: Codable, Identifiable, Sendable, Equatable {
        var id = UUID()
        /// Security-scoped bookmark data for the splat file
        var bookmarkData: Data
        /// Per-cloud transform (applied before scene transform)
        var transform: Transform = .identity
        /// Whether this cloud should be rendered
        var enabled: Bool = true
        /// Display name (defaults to filename)
        var displayName: String?
        /// Cloud opacity (0.0 - 1.0)
        var opacity: Float = 1.0
        /// Debug color for this cloud (shown in debug mode)
        var debugColor: SIMD3<Float> = [1, 1, 1]

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
        // swiftlint:disable:next nesting
        enum CodingKeys: String, CodingKey {
            case id, bookmarkData, transform, enabled, displayName, opacity, debugColor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
            transform = try container.decodeIfPresent(Transform.self, forKey: .transform) ?? .identity
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            opacity = try container.decodeIfPresent(Float.self, forKey: .opacity) ?? 1.0
            debugColor = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .debugColor) ?? [1, 1, 1]
        }
    }

    struct CameraState: Codable, Sendable, Equatable {
        /// Camera position and orientation as a 4x4 matrix
        var matrix: simd_float4x4
        /// Vertical field of view in degrees
        var verticalAngleOfView: Double
        /// Camera mode (object, room, spatialScene)
        var mode: String = "object"

        init(matrix: simd_float4x4 = .identity, verticalAngleOfView: Double = 60.0, mode: String = "object") {
            self.matrix = matrix
            self.verticalAngleOfView = verticalAngleOfView
            self.mode = mode
        }

        // Custom decoder for backward compatibility
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            matrix = try container.decode(simd_float4x4.self, forKey: .matrix)
            verticalAngleOfView = try container.decode(Double.self, forKey: .verticalAngleOfView)
            mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "object"
        }

        private enum CodingKeys: String, CodingKey {
            case matrix, verticalAngleOfView, mode
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

import Foundation
import simd

/// Configuration for rendering Gaussian splats
struct RenderConfig: Codable {
    /// Background color in RGBA format
    var background: [Float] = [0, 0, 0, 1]

    /// Width of the output image
    var width: Int = 1_024

    /// Height of the output image
    var height: Int = 768

    /// Output PNG file path
    var output: String = "output.png"

    /// Model position in x,y,z format
    var modelPosition: [Float]?

    /// Camera position in x,y,z format
    var cameraPosition: [Float]?

    /// Camera look-at target in x,y,z format
    var cameraLookat: [Float]?

    /// Camera rotation as quaternion [x,y,z,w] or 3x3 matrix (9 values)
    var cameraRotation: [Float]?

    /// Camera-to-world matrix, 16 column-major values. Overrides the other
    /// camera fields.
    var cameraMatrix: [Float]?

    /// Projection field of view in degrees
    var projectionFov: Double?

    /// Camera near clipping plane
    var near: Float = 0.1

    /// Camera far clipping plane
    var far: Float = 100.0

    /// Path to splat file (.ply, .spz, .sog) to render
    var splat: String

    /// Renderer to use (currently only "spark" is supported)
    var renderer: String?

    /// Convert sRGB to linear in fragment shader (for Spark renderer)
    var srgbToLinear: Bool?

    // MARK: - Helpers

    func getBackground() -> SIMD4<Float> {
        guard background.count == 4 else {
            return SIMD4<Float>(0, 0, 0, 1)
        }
        return SIMD4<Float>(background[0], background[1], background[2], background[3])
    }

    func getModelPosition() -> SIMD3<Float>? {
        guard let pos = modelPosition, pos.count == 3 else {
            return nil
        }
        return SIMD3<Float>(pos[0], pos[1], pos[2])
    }

    func getCameraPosition() -> SIMD3<Float>? {
        guard let pos = cameraPosition, pos.count == 3 else {
            return nil
        }
        return SIMD3<Float>(pos[0], pos[1], pos[2])
    }

    func getCameraLookat() -> SIMD3<Float>? {
        guard let lookat = cameraLookat, lookat.count == 3 else {
            return nil
        }
        return SIMD3<Float>(lookat[0], lookat[1], lookat[2])
    }

    func getCameraRotation() -> [Float]? {
        cameraRotation
    }

    func getCameraMatrix() -> simd_float4x4? {
        guard let matrix = cameraMatrix, matrix.count == 16 else {
            return nil
        }
        return simd_float4x4(
            SIMD4<Float>(matrix[0], matrix[1], matrix[2], matrix[3]),
            SIMD4<Float>(matrix[4], matrix[5], matrix[6], matrix[7]),
            SIMD4<Float>(matrix[8], matrix[9], matrix[10], matrix[11]),
            SIMD4<Float>(matrix[12], matrix[13], matrix[14], matrix[15])
        )
    }

    /// Save configuration to JSON file
    func save(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Load configuration from JSON file
    static func load(from path: String) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        return try decoder.decode(Self.self, from: data)
    }
}

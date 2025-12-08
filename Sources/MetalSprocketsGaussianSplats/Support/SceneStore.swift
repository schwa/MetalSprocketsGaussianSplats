#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import simd
import SwiftUI

/// Axis rotation settings for scene orientation
public struct AxisSettings: Codable, Equatable, Sendable {
    public var rotationX: Float
    public var rotationY: Float
    public var rotationZ: Float

    public init(rotationX: Float = .pi, rotationY: Float = 0, rotationZ: Float = 0) {
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.rotationZ = rotationZ
    }

    public static let `default` = AxisSettings()
}

/// A saved scene with camera, splat file, and axis settings
public struct SavedScene: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let cameraMatrix: simd_float4x4
    public let splatURL: URL?
    public let axisSettings: AxisSettings
    public let savedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        cameraMatrix: simd_float4x4,
        splatURL: URL?,
        axisSettings: AxisSettings,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.cameraMatrix = cameraMatrix
        self.splatURL = splatURL
        self.axisSettings = axisSettings
        self.savedAt = savedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, cameraMatrix, splatURL, axisSettings, savedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        splatURL = try container.decodeIfPresent(URL.self, forKey: .splatURL)
        axisSettings = try container.decodeIfPresent(AxisSettings.self, forKey: .axisSettings) ?? .default

        let matrixArray = try container.decode([Float].self, forKey: .cameraMatrix)
        guard matrixArray.count == 16 else {
            throw DecodingError.dataCorruptedError(forKey: .cameraMatrix, in: container, debugDescription: "Matrix must have 16 elements")
        }
        cameraMatrix = simd_float4x4(
            SIMD4<Float>(matrixArray[0], matrixArray[1], matrixArray[2], matrixArray[3]),
            SIMD4<Float>(matrixArray[4], matrixArray[5], matrixArray[6], matrixArray[7]),
            SIMD4<Float>(matrixArray[8], matrixArray[9], matrixArray[10], matrixArray[11]),
            SIMD4<Float>(matrixArray[12], matrixArray[13], matrixArray[14], matrixArray[15])
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encodeIfPresent(splatURL, forKey: .splatURL)
        try container.encode(axisSettings, forKey: .axisSettings)

        let matrixArray: [Float] = [
            cameraMatrix.columns.0.x, cameraMatrix.columns.0.y, cameraMatrix.columns.0.z, cameraMatrix.columns.0.w,
            cameraMatrix.columns.1.x, cameraMatrix.columns.1.y, cameraMatrix.columns.1.z, cameraMatrix.columns.1.w,
            cameraMatrix.columns.2.x, cameraMatrix.columns.2.y, cameraMatrix.columns.2.z, cameraMatrix.columns.2.w,
            cameraMatrix.columns.3.x, cameraMatrix.columns.3.y, cameraMatrix.columns.3.z, cameraMatrix.columns.3.w
        ]
        try container.encode(matrixArray, forKey: .cameraMatrix)
    }
}

/// Observable store for managing saved scenes
@Observable
@MainActor
public final class SceneStore {
    public static let shared = SceneStore()

    private static let maxSavedScenes = 10
    private static let userDefaultsKey = "SavedScenes"

    public private(set) var savedScenes: [SavedScene] = []

    private init() {
        loadFromUserDefaults()
    }

    public func saveScene(
        name: String,
        cameraMatrix: simd_float4x4,
        splatURL: URL?,
        axisSettings: AxisSettings
    ) {
        let scene = SavedScene(
            name: name,
            cameraMatrix: cameraMatrix,
            splatURL: splatURL,
            axisSettings: axisSettings
        )
        savedScenes.insert(scene, at: 0)

        // Keep only the last N scenes
        if savedScenes.count > Self.maxSavedScenes {
            savedScenes = Array(savedScenes.prefix(Self.maxSavedScenes))
        }

        saveToUserDefaults()
    }

    public func deleteScene(_ scene: SavedScene) {
        savedScenes.removeAll { $0.id == scene.id }
        saveToUserDefaults()
    }

    public func deleteScene(at index: Int) {
        guard savedScenes.indices.contains(index) else {
            return
        }
        savedScenes.remove(at: index)
        saveToUserDefaults()
    }

    public func clearAll() {
        savedScenes.removeAll()
        saveToUserDefaults()
    }

    private func saveToUserDefaults() {
        do {
            let data = try JSONEncoder().encode(savedScenes)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        } catch {
            print("Failed to save scenes: \(error)")
        }
    }

    private func loadFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey) else {
            return
        }
        do {
            savedScenes = try JSONDecoder().decode([SavedScene].self, from: data)
        } catch {
            print("Failed to load scenes: \(error)")
        }
    }
}
#endif

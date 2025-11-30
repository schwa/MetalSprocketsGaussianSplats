#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import simd
import SwiftUI

/// A saved camera transform with metadata
public struct SavedCamera: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let matrix: simd_float4x4
    public let savedAt: Date

    public init(id: UUID = UUID(), name: String, matrix: simd_float4x4, savedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.matrix = matrix
        self.savedAt = savedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, matrix, savedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        let matrixArray = try container.decode([Float].self, forKey: .matrix)
        guard matrixArray.count == 16 else {
            throw DecodingError.dataCorruptedError(forKey: .matrix, in: container, debugDescription: "Matrix must have 16 elements")
        }
        matrix = simd_float4x4(
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
        let matrixArray: [Float] = [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
        try container.encode(matrixArray, forKey: .matrix)
    }
}

/// Observable store for managing saved camera positions
@Observable
@MainActor
public final class CameraStore {
    public static let shared = CameraStore()

    private static let maxSavedCameras = 10
    private static let userDefaultsKey = "SavedCameras"

    public private(set) var savedCameras: [SavedCamera] = []

    private init() {
        loadFromUserDefaults()
    }

    public func saveCamera(name: String, matrix: simd_float4x4) {
        let camera = SavedCamera(name: name, matrix: matrix)
        savedCameras.insert(camera, at: 0)

        // Keep only the last N cameras
        if savedCameras.count > Self.maxSavedCameras {
            savedCameras = Array(savedCameras.prefix(Self.maxSavedCameras))
        }

        saveToUserDefaults()
    }

    public func deleteCamera(_ camera: SavedCamera) {
        savedCameras.removeAll { $0.id == camera.id }
        saveToUserDefaults()
    }

    public func deleteCamera(at index: Int) {
        guard savedCameras.indices.contains(index) else {
            return
        }
        savedCameras.remove(at: index)
        saveToUserDefaults()
    }

    public func clearAll() {
        savedCameras.removeAll()
        saveToUserDefaults()
    }

    private func saveToUserDefaults() {
        do {
            let data = try JSONEncoder().encode(savedCameras)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        } catch {
            print("Failed to save cameras: \(error)")
        }
    }

    private func loadFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey) else {
            return
        }
        do {
            savedCameras = try JSONDecoder().decode([SavedCamera].self, from: data)
        } catch {
            print("Failed to load cameras: \(error)")
        }
    }
}
#endif

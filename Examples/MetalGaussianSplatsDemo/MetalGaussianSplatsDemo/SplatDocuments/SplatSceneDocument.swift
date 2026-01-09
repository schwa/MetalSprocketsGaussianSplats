import SwiftUI
import UniformTypeIdentifiers
import simd

/// A document representing a splat scene with multiple clouds
struct SplatSceneDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.splatScene] }
    static var writableContentTypes: [UTType] { [.splatScene] }

    var scene: SplatScene

    init() {
        self.scene = SplatScene()
    }

    init(scene: SplatScene) {
        self.scene = scene
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        do {
            self.scene = try decoder.decode(SplatScene.self, from: data)
        } catch {
            print("❌ Failed to decode SplatScene: \(error)")
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let context):
                    print("  Key not found: \(key.stringValue), path: \(context.codingPath.map(\.stringValue).joined(separator: "."))")
                case .typeMismatch(let type, let context):
                    print("  Type mismatch: expected \(type), path: \(context.codingPath.map(\.stringValue).joined(separator: "."))")
                case .valueNotFound(let type, let context):
                    print("  Value not found: \(type), path: \(context.codingPath.map(\.stringValue).joined(separator: "."))")
                case .dataCorrupted(let context):
                    print("  Data corrupted: \(context.debugDescription)")
                @unknown default:
                    break
                }
            }
            throw error
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(scene)
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Security Scoped Resource Access

/// Helper to manage security-scoped resource access for multiple URLs
final class ScopedResourceAccess {
    private var accessingURLs: [URL] = []

    /// Start accessing all cloud URLs in a scene
    func startAccessing(scene: SplatScene) throws -> [ResolvedCloud] {
        var resolved: [ResolvedCloud] = []

        for cloud in scene.clouds where cloud.enabled {
            do {
                let (url, isStale) = try cloud.resolveURL()
                #if os(macOS)
                if url.startAccessingSecurityScopedResource() {
                    accessingURLs.append(url)
                }
                #endif
                resolved.append(ResolvedCloud(
                    id: cloud.id,
                    url: url,
                    transform: cloud.transform,
                    displayName: cloud.displayName,
                    isStale: isStale
                ))
            } catch {
                // Log but continue with other clouds
                print("Failed to resolve cloud \(cloud.id): \(error)")
            }
        }

        return resolved
    }

    /// Stop accessing all resources
    func stopAccessing() {
        #if os(macOS)
        for url in accessingURLs {
            url.stopAccessingSecurityScopedResource()
        }
        #endif
        accessingURLs.removeAll()
    }

    deinit {
        stopAccessing()
    }
}

/// A resolved cloud reference with an accessible URL
struct ResolvedCloud: Identifiable {
    let id: UUID
    let url: URL
    let transform: simd_float4x4
    let displayName: String?
    let isStale: Bool
}

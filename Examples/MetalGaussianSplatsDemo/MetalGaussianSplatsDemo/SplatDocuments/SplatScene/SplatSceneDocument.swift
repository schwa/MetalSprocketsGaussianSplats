import simd
import SwiftUI
import UniformTypeIdentifiers

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
        self.scene = try decoder.decode(SplatScene.self, from: data)
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
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
                // Continue with other clouds if one fails to resolve
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
    let transform: Transform
    let displayName: String?
    let isStale: Bool
}

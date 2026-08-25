import Foundation
import MetalCompilerPluginSupport

extension Bundle {
    static var metalSprocketsGaussianSplatsDebugShaders: Bundle {
        let parentURL = Self.module.bundleURL.deletingLastPathComponent()
        let suffix = "_MetalSprocketsGaussianSplatsDebugShaders.bundle"
        guard let name = try? FileManager.default.contentsOfDirectory(atPath: parentURL.path).first(where: { $0.hasSuffix(suffix) }), let bundle = Bundle(url: parentURL.appending(path: name)) else {
            fatalError("Failed to load MetalSprocketsGaussianSplatsDebugShaders bundle")
        }
        return bundle
    }
}

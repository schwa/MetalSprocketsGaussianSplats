import Foundation
import MetalCompilerPluginSupport

public extension Bundle {
    static var metalSprocketsGaussianSplatShaders: Bundle {
        guard let bundle = Self.module.peerBundle(withSuffix: "MetalSprocketsGaussianSplatShaders") else {
            fatalError("Failed to load MetalSprocketsGaussianSplatShaders bundle. Parent bundle: \(String(describing: Self.module.parentBundle)), searched for suffix: MetalSprocketsGaussianSplatShaders")
        }
        return bundle
    }
}

internal extension Bundle {
    func peerBundle(withSuffix suffix: String) -> Bundle? {
        let url = bundleURL.deletingLastPathComponent()
        let fileManager = FileManager()
        guard let filename = try? fileManager.contentsOfDirectory(atPath: url.path).first(where: { $0.hasSuffix("_\(suffix).bundle") }) else {
            return nil
        }
        let bundleURL = url.appendingPathComponent(filename)
        return Bundle(url: bundleURL)
    }
}

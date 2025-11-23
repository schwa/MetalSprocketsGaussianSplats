import Foundation
import MetalCompilerPluginSupport

extension Bundle {
    static var metalSprocketsGaussianSplatShaders: Bundle {
        guard let bundle = Bundle.module.parentBundle?.childBundle(withSuffix: "MetalSprocketsGaussianSplatShaders") else {
            fatalError()
        }
        return bundle
    }
}

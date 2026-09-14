import ArgumentParser
import MetalSprocketsGaussianSplats

extension SplatSortPrecision: ExpressibleByArgument {
    public init?(argument: String) {
        guard let bits = Int(argument), let precision = Self(rawValue: bits) else {
            return nil
        }
        self = precision
    }
}

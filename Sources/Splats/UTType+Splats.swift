import UniformTypeIdentifiers

public extension UTType {
    /// Polygon File Format (.ply)
    nonisolated static let ply = UTType(importedAs: "public.polygon-file-format")

    /// Antimatter15 Splat (.splat) format
    nonisolated static let antimatter15Splat = UTType(importedAs: "com.antimatter15.splat")

    /// Gaussian Splat SPZ (.spz) format (Niantic Labs)
    nonisolated static let spz = UTType(importedAs: "com.nianticlabs.spz")

    /// SOG, Spatially Ordered Gaussians (.sog) format (PlayCanvas)
    nonisolated static let sog = UTType(importedAs: "com.playcanvas.sog")
}

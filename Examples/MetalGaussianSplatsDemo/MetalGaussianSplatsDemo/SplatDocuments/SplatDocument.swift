import SwiftUI
import UniformTypeIdentifiers

// MARK: - UTType Extensions for Gaussian Splats

public extension UTType {
    /// SOG - Spatially Ordered Gaussians (.sog) format (PlayCanvas)
    static var sog: UTType {
        UTType(importedAs: "com.playcanvas.sog")
    }

    /// Polygon File Format (.ply)
    static var ply: UTType {
        UTType(importedAs: "public.polygon-file-format")
    }

    /// Antimatter15 Splat (.splat) format
    static var antimatter15Splat: UTType {
        UTType(importedAs: "com.antimatter15.splat")
    }

    /// Gaussian Splat SPZ (.spz) format (Niantic Labs)
    static var spz: UTType {
        UTType(importedAs: "com.nianticlabs.spz")
    }
}

// MARK: - SplatDocument

/// A document type for Gaussian Splat files.
/// Supports .sog, .ply, .splat, and .spv file formats.
/// This document only stores metadata - the actual splat data is loaded by the view.
struct SplatDocument: FileDocument {
    /// The file type of the document
    var contentType: UTType?

    static var readableContentTypes: [UTType] {
        [.sog, .ply, .antimatter15Splat, .spz, .image]
    }

    static var writableContentTypes: [UTType] {
        [] // Read-only document
    }

    init() {
        contentType = nil
    }

    init(configuration: ReadConfiguration) throws {
        // Don't load the data here - let the view handle loading from the file URL
        contentType = configuration.contentType
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission) // Read-only document
    }
}

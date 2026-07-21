import Foundation

/// A reader that decodes Gaussian splats from a specific file format.
///
/// Conforming types stream splats one at a time via ``read(_:)``, converting
/// each record to an `ExtendedSplat`. Use ``SplatReader`` to pick a reader
/// automatically from a file extension.
public protocol SplatReaderProtocol {
    /// The total number of splats in the file.
    var splatCount: Int { get }
    /// Spherical harmonics degree of the file's splats (0 = none).
    var shDegree: UInt8 { get }

    init(url: URL) throws
    init(data: Data) throws
    func read(_ handler: (Int, ExtendedSplat) throws -> Void) throws
}

public extension SplatReaderProtocol {
    var shDegree: UInt8 { 0 }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }
}

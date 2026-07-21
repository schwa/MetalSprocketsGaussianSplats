import Foundation

public protocol SplatReaderProtocol {
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

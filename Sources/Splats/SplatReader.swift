import Foundation

/// A splat reader that automatically selects the appropriate format reader based on file extension.
public struct SplatReader: SplatReaderProtocol {
    private let inner: any SplatReaderProtocol

    public var splatCount: Int {
        inner.splatCount
    }

    public init(url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "ply":
            inner = try PLYSplatReader(url: url)
        case "splat":
            inner = try Antimatter15Reader(url: url)
        case "sog":
            inner = try SOGReaderCPU(url: url)
        case "spz":
            inner = try SPZReader(url: url)
        default:
            throw SplatsError.unsupportedFormat(url.pathExtension)
        }
    }

    public init(data _: Data) throws {
        throw SplatsError.unsupportedFormat("unknown (data-only init requires a URL to determine format)")
    }

    public func read(_ handler: (Int, ExtendedSplat) throws -> Void) throws {
        try inner.read(handler)
    }
}

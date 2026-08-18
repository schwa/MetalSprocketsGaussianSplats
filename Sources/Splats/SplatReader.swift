import Foundation

/// A splat reader that automatically selects the appropriate format reader based on file extension.
public struct SplatReader: SplatReaderProtocol {
    private let inner: any SplatReaderProtocol

    public var splatCount: Int {
        inner.splatCount
    }

    public var shDegree: UInt8 {
        inner.shDegree
    }

    public init(url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "ply":
            inner = try PLYSplatReader(url: url)
        case "splat":
            throw SplatsError.unsupportedFormat("splat (Antimatter15 format has been removed, use .spz or .ply)")
        case "sog":
            // SOG decodes on the GPU only (SOGReaderGPU); there is no device-free
            // CPU decoder. Use SplatLoader (which requires an MTLDevice).
            throw SplatsError.unsupportedFormat("sog (decode on the GPU via SplatLoader; SplatReader is device-free)")
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

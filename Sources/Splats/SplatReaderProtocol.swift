import Foundation

public protocol SplatReaderProtocol {
    var splatCount: Int { get }

    init(url: URL) throws
    init(data: Data) throws
    func read(_ handler: (Int, ExtendedSplat) throws -> Void) throws
}

public extension SplatReaderProtocol {
    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }
}

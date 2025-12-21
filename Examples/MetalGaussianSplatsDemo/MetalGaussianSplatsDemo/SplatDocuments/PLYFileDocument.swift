import SwiftUI
import UniformTypeIdentifiers

/// A simple document wrapper for exporting PLY files
struct PLYFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.ply] }
    static var writableContentTypes: [UTType] { [.ply] }

    let data: Data

    init(url: URL) {
        self.data = (try? Data(contentsOf: url)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

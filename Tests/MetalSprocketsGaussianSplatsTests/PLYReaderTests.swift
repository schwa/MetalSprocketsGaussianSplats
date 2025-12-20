import Foundation
@testable import MetalSprocketsGaussianSplats
import Splats
import Testing

// MARK: - Test-only extensions

extension PLYReader {
    var recordStruct: [Property] {
        primaryElement?.properties ?? []
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }
}

@Suite("PLYReader Tests")
struct PLYReaderTests {
    // MARK: - Test Fixtures

    static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    // MARK: - ASCII Tests

    @Test("Read ASCII PLY file")
    func testReadASCII() throws {
        let url = Self.fixturesURL.appendingPathComponent("test_ascii.ply")
        let reader = try PLYReader(url: url)

        #expect(reader.format == .ascii)
        #expect(reader.recordCount == 3)
        #expect(reader.recordStruct.count == 6)

        // Verify properties
        let properties = reader.recordStruct
        #expect(properties[0].name == "x")
        #expect(properties[0].type == .float)
        #expect(properties[1].name == "y")
        #expect(properties[2].name == "z")
        #expect(properties[3].name == "red")
        #expect(properties[3].type == .uchar)

        // Read records
        var records: [PLYReader.Record] = []
        try reader.read { record in
            records.append(record)
        }

        #expect(records.count == 3)

        // Check first vertex
        if case .float(let x) = records[0]["x"] { #expect(x == 0.0) }
        if case .float(let y) = records[0]["y"] { #expect(y == 0.0) }
        if case .float(let z) = records[0]["z"] { #expect(z == 0.0) }
        if case .uchar(let red) = records[0]["red"] { #expect(red == 255) }
        if case .uchar(let green) = records[0]["green"] { #expect(green == 0) }
        if case .uchar(let blue) = records[0]["blue"] { #expect(blue == 0) }

        // Check second vertex
        if case .float(let x) = records[1]["x"] { #expect(x == 1.0) }
        if case .uchar(let green) = records[1]["green"] { #expect(green == 255) }

        // Check third vertex
        if case .float(let y) = records[2]["y"] { #expect(y == 1.0) }
        if case .uchar(let blue) = records[2]["blue"] { #expect(blue == 255) }
    }

    @Test("Read ASCII PLY with list properties")
    func testReadASCIIWithList() throws {
        let url = Self.fixturesURL.appendingPathComponent("test_ascii_with_list.ply")
        let reader = try PLYReader(url: url)

        #expect(reader.format == .ascii)
        #expect(reader.elements.count == 2)

        // Check vertex element
        let vertexElement = reader.elements[0]
        #expect(vertexElement.name == "vertex")
        #expect(vertexElement.count == 2)

        var vertices: [PLYReader.Record] = []
        try reader.read(element: vertexElement) { record in
            vertices.append(record)
        }

        #expect(vertices.count == 2)
        if case .float(let x) = vertices[0]["x"] { #expect(x == 1.0) }
        if case .float(let y) = vertices[0]["y"] { #expect(y == 2.0) }
        if case .float(let z) = vertices[0]["z"] { #expect(z == 3.0) }

        // Check face element
        let faceElement = reader.elements[1]
        #expect(faceElement.name == "face")
        #expect(faceElement.count == 1)
        #expect(faceElement.properties[0].isList == true)

        var faces: [PLYReader.Record] = []
        try reader.read(element: faceElement) { record in
            faces.append(record)
        }

        #expect(faces.count == 1)

        if case .list(let indices) = faces[0]["vertex_indices"] {
            #expect(indices.count == 3)
            if case .int(let idx) = indices[0] { #expect(idx == 0) }
            if case .int(let idx) = indices[1] { #expect(idx == 1) }
            if case .int(let idx) = indices[2] { #expect(idx == 2) }
        } else {
            Issue.record("Expected list property")
        }
    }

    // MARK: - Binary Tests

    @Test("Read binary little endian PLY file")
    func testReadBinaryLittleEndian() throws {
        let url = try createBinaryPLY(littleEndian: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try PLYReader(url: url)

        #expect(reader.format == .binaryLittleEndian)
        #expect(reader.recordCount == 2)

        var records: [PLYReader.Record] = []
        try reader.read { record in
            records.append(record)
        }

        #expect(records.count == 2)
        if case .float(let x) = records[0]["x"] { #expect(x == 1.5) }
        if case .float(let y) = records[0]["y"] { #expect(y == 2.5) }
        if case .float(let z) = records[0]["z"] { #expect(z == 3.5) }
        if case .float(let x) = records[1]["x"] { #expect(x == 4.5) }
        if case .float(let y) = records[1]["y"] { #expect(y == 5.5) }
        if case .float(let z) = records[1]["z"] { #expect(z == 6.5) }
    }

    @Test("Read binary big endian PLY file")
    func testReadBinaryBigEndian() throws {
        let url = try createBinaryPLY(littleEndian: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try PLYReader(url: url)

        #expect(reader.format == .binaryBigEndian)
        #expect(reader.recordCount == 2)

        var records: [PLYReader.Record] = []
        try reader.read { record in
            records.append(record)
        }

        #expect(records.count == 2)
        if case .float(let x) = records[0]["x"] { #expect(x == 1.5) }
        if case .float(let y) = records[0]["y"] { #expect(y == 2.5) }
        if case .float(let z) = records[0]["z"] { #expect(z == 3.5) }
    }

    // MARK: - Property Type Tests

    @Test("Read various property types")
    func testPropertyTypes() throws {
        let url = try createMultiTypePLY()
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try PLYReader(url: url)

        var records: [PLYReader.Record] = []
        try reader.read { record in
            records.append(record)
        }

        #expect(records.count == 1)
        let record = records[0]

        if case .char(let v) = record["prop_char"] { #expect(v == -42) }
        if case .uchar(let v) = record["prop_uchar"] { #expect(v == 200) }
        if case .short(let v) = record["prop_short"] { #expect(v == -1_000) }
        if case .ushort(let v) = record["prop_ushort"] { #expect(v == 50_000) }
        if case .int(let v) = record["prop_int"] { #expect(v == -100_000) }
        if case .uint(let v) = record["prop_uint"] { #expect(v == 200_000) }
        if case .float(let v) = record["prop_float"] { #expect(v == 3.14159) }

        if let doubleVal = record["prop_double"] {
            if case .double(let val) = doubleVal {
                #expect(abs(val - 2.71828) < 0.00001)
            }
        }
    }

    // MARK: - Data Initialization Tests

    @Test("Initialize with Data directly")
    func testDataInitialization() throws {
        let plyString = """
        ply
        format ascii 1.0
        element vertex 2
        property float x
        property float y
        property float z
        end_header
        1.0 2.0 3.0
        4.0 5.0 6.0
        """

        let data = Data(plyString.utf8)
        let reader = try PLYReader(data: data)

        #expect(reader.format == .ascii)
        #expect(reader.recordCount == 2)

        var records: [PLYReader.Record] = []
        try reader.read { record in
            records.append(record)
        }

        #expect(records.count == 2)
        if case .float(let x) = records[0]["x"] { #expect(x == 1.0) }
        if case .float(let y) = records[0]["y"] { #expect(y == 2.0) }
        if case .float(let z) = records[0]["z"] { #expect(z == 3.0) }
        if case .float(let x) = records[1]["x"] { #expect(x == 4.0) }
        if case .float(let y) = records[1]["y"] { #expect(y == 5.0) }
        if case .float(let z) = records[1]["z"] { #expect(z == 6.0) }
    }

    @Test("Initialize binary PLY with Data")
    func testBinaryDataInitialization() throws {
        let formatString = "binary_little_endian"
        let header = """
        ply
        format \(formatString) 1.0
        element vertex 1
        property float x
        property float y
        property float z
        end_header

        """

        var data = Data(header.utf8)

        // Write binary vertex data
        let x: Float = 7.5
        let y: Float = 8.5
        let z: Float = 9.5

        withUnsafeBytes(of: x.bitPattern) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: y.bitPattern) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: z.bitPattern) { data.append(contentsOf: $0) }

        let reader = try PLYReader(data: data)

        #expect(reader.format == .binaryLittleEndian)
        #expect(reader.recordCount == 1)

        var records: [PLYReader.Record] = []
        try reader.read { record in
            records.append(record)
        }

        #expect(records.count == 1)
        if case .float(let x) = records[0]["x"] { #expect(x == 7.5) }
        if case .float(let y) = records[0]["y"] { #expect(y == 8.5) }
        if case .float(let z) = records[0]["z"] { #expect(z == 9.5) }
    }

    // MARK: - Error Tests

    @Test("Invalid header throws error")
    func testInvalidHeader() throws {
        let url = try createInvalidPLY()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: PLYError.self) {
            _ = try PLYReader(url: url)
        }
    }

    @Test("Missing end_header throws error")
    func testMissingEndHeader() throws {
        let url = try createPLYWithoutEndHeader()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: PLYError.missingEndHeader) {
            _ = try PLYReader(url: url)
        }
    }

    // MARK: - Helper Methods

    private func createBinaryPLY(littleEndian: Bool) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ply")

        let formatString = littleEndian ? "binary_little_endian" : "binary_big_endian"
        let header = """
        ply
        format \(formatString) 1.0
        element vertex 2
        property float x
        property float y
        property float z
        end_header

        """

        var data = Data(header.utf8)

        // Write binary vertex data
        let vertices: [(Float, Float, Float)] = [(1.5, 2.5, 3.5), (4.5, 5.5, 6.5)]

        for vertex in vertices {
            var x = vertex.0.bitPattern
            var y = vertex.1.bitPattern
            var z = vertex.2.bitPattern

            if !littleEndian {
                x = x.byteSwapped
                y = y.byteSwapped
                z = z.byteSwapped
            }

            withUnsafeBytes(of: x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: z) { data.append(contentsOf: $0) }
        }

        try data.write(to: tempURL)
        return tempURL
    }

    private func createMultiTypePLY() throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ply")

        let header = """
        ply
        format ascii 1.0
        element vertex 1
        property char prop_char
        property uchar prop_uchar
        property short prop_short
        property ushort prop_ushort
        property int prop_int
        property uint prop_uint
        property float prop_float
        property double prop_double
        end_header
        -42 200 -1000 50000 -100000 200000 3.14159 2.71828
        """

        try header.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    private func createInvalidPLY() throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ply")

        let content = """
        ply
        format invalid_format 1.0
        end_header
        """

        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    private func createPLYWithoutEndHeader() throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ply")

        let content = """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        """

        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }
}

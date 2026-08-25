import Foundation
import UniformTypeIdentifiers

/// A general-purpose PLY file parser supporting ASCII and binary encodings.
///
/// Parses the PLY header and streams element records to a handler. Use
/// ``PLYSplatReader`` for Gaussian-splat-specific decoding built on top of
/// this reader.
public struct PLYReader {
    /// The encoding of a PLY file's body, as declared in its header.
    public enum Format {
        case ascii
        case binaryLittleEndian
        case binaryBigEndian
    }

    public enum PropertyType {
        case char, uchar
        case short, ushort
        case int, uint
        case float, double
    }

    public struct Property {
        public let name: String
        public let type: PropertyType
        public let isList: Bool
        public let listCountType: PropertyType?
        public let listItemType: PropertyType?
    }

    public struct Element {
        public let name: String
        public let count: Int
        public let properties: [Property]
    }

    public enum PropertyValue {
        case char(Int8)
        case uchar(UInt8)
        case short(Int16)
        case ushort(UInt16)
        case int(Int32)
        case uint(UInt32)
        case float(Float)
        case double(Double)
        case list([Self])
    }

    public typealias Record = [String: PropertyValue]

    public let data: Data
    public private(set) var format: Format?
    public private(set) var elements: [Element] = []

    public var primaryElement: Element? {
        elements.first
    }

    public var recordCount: Int {
        primaryElement?.count ?? 0
    }

    private var headerEndOffset: Int = 0

    public init(data: Data) throws {
        self.data = data
        try parseHeader()
    }

    private mutating func parseHeader() throws {
        let data = self.data

        var headerData = Data()
        var offset = 0

        while offset < data.count {
            if data[offset] == 0x0A {
                let line = String(data: headerData, encoding: .ascii) ?? ""
                if line.trimmingCharacters(in: .whitespaces) == "end_header" {
                    offset += 1
                    break
                }
                headerData.removeAll()
                offset += 1
            } else {
                headerData.append(data[offset])
                offset += 1
            }
        }

        headerEndOffset = offset

        let headerBytes = data[0..<headerEndOffset]
        guard let headerString = String(data: headerBytes, encoding: .ascii) else {
            throw SplatsError.invalidEncoding
        }

        let lines = headerString.components(separatedBy: .newlines)
        var currentElement: (name: String, count: Int, properties: [Property])?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("comment") {
                continue
            }

            let parts = trimmed.split(separator: " ").map(String.init)

            guard let keyword = parts.first else { continue }

            switch keyword {
            case "ply":
                continue

            case "format":
                guard parts.count >= 2 else { throw SplatsError.invalidHeader }
                switch parts[1] {
                case "ascii":
                    format = .ascii

                case "binary_little_endian":
                    format = .binaryLittleEndian

                case "binary_big_endian":
                    format = .binaryBigEndian

                default:
                    throw SplatsError.unsupportedFormat(parts[1])
                }

            case "element":
                if let element = currentElement {
                    elements.append(Element(name: element.name, count: element.count, properties: element.properties))
                }

                guard parts.count >= 3, let count = Int(parts[2]) else {
                    throw SplatsError.invalidHeader
                }
                currentElement = (name: parts[1], count: count, properties: [])

            case "property":
                guard var element = currentElement else { throw SplatsError.invalidHeader }

                if parts[1] == "list" {
                    guard parts.count >= 5, let countType = PropertyType(string: parts[2]), let itemType = PropertyType(string: parts[3]) else {
                        throw SplatsError.invalidHeader
                    }
                    let property = Property(
                        name: parts[4],
                        type: itemType,
                        isList: true,
                        listCountType: countType,
                        listItemType: itemType
                    )
                    element.properties.append(property)
                } else {
                    guard parts.count >= 3, let type = PropertyType(string: parts[1]) else {
                        throw SplatsError.invalidHeader
                    }
                    let property = Property(
                        name: parts[2],
                        type: type,
                        isList: false,
                        listCountType: nil,
                        listItemType: nil
                    )
                    element.properties.append(property)
                }

                currentElement = element

            case "end_header":
                if let element = currentElement {
                    elements.append(Element(name: element.name, count: element.count, properties: element.properties))
                }
                return

            default:
                continue
            }
        }

        throw SplatsError.missingEndHeader
    }

    public func read(_ callback: (Record) throws -> Void) throws {
        guard let element = primaryElement else {
            throw SplatsError.noElements
        }
        try read(element: element, callback: callback)
    }

    public func read(element: Element, callback: (Record) throws -> Void) throws {
        let properties = element.properties
        try readValues(element: element) { values in
            var record = Record(minimumCapacity: properties.count)
            for (index, value) in values.enumerated() {
                if let value {
                    record[properties[index].name] = value
                }
            }
            try callback(record)
        }
    }

    /// Streams each record as property values in header declaration order.
    ///
    /// The array is reused between callbacks. An entry is nil when an ASCII
    /// scalar fails to parse.
    public func readValues(element: Element, callback: ([PropertyValue?]) throws -> Void) throws {
        guard let format else {
            throw SplatsError.formatNotSet
        }

        switch format {
        case .ascii:
            try readASCII(element: element, callback: callback)

        case .binaryLittleEndian:
            try readBinary(element: element, littleEndian: true, callback: callback)

        case .binaryBigEndian:
            try readBinary(element: element, littleEndian: false, callback: callback)
        }
    }

    private func readASCII(element: Element, callback: ([PropertyValue?]) throws -> Void) throws {
        guard let content = String(data: data, encoding: .utf8) else {
            throw SplatsError.invalidEncoding
        }
        let lines = content.components(separatedBy: .newlines)

        var lineIndex = 0
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "end_header" {
            lineIndex = index + 1
            break
        }

        var recordsRead = 0
        for el in elements {
            if el.name == element.name {
                break
            }
            recordsRead += el.count
        }
        lineIndex += recordsRead

        for i in 0..<element.count {
            guard lineIndex + i < lines.count else { break }
            let line = lines[lineIndex + i].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let values = line.split(separator: " ").map(String.init)
            var valueIndex = 0
            var rowValues: [PropertyValue?] = []
            rowValues.reserveCapacity(element.properties.count)

            for property in element.properties {
                if property.isList {
                    guard valueIndex < values.count, let listCount = Int(values[valueIndex]) else {
                        throw SplatsError.invalidData
                    }
                    valueIndex += 1

                    var listValues: [PropertyValue] = []
                    for _ in 0..<listCount {
                        guard valueIndex < values.count else { throw SplatsError.invalidData }
                        if let value = PropertyValue(string: values[valueIndex], type: property.listItemType ?? property.type) {
                            listValues.append(value)
                        }
                        valueIndex += 1
                    }
                    rowValues.append(.list(listValues))
                } else {
                    guard valueIndex < values.count else { throw SplatsError.invalidData }
                    rowValues.append(PropertyValue(string: values[valueIndex], type: property.type))
                    valueIndex += 1
                }
            }

            try callback(rowValues)
        }
    }

    private func readBinary(element: Element, littleEndian: Bool, callback: ([PropertyValue?]) throws -> Void) throws {
        let data = self.data

        var offset = headerEndOffset
        for el in elements {
            if el.name == element.name {
                break
            }
            offset += el.count * el.properties.reduce(0) { sum, prop in
                sum + (prop.isList ? 0 : prop.type.size)
            }
        }

        var rowValues: [PropertyValue?] = []
        rowValues.reserveCapacity(element.properties.count)

        try data.withUnsafeBytes { buffer in
            let bytes = RawSpan(_unsafeBytes: buffer)
        for _ in 0..<element.count {
            rowValues.removeAll(keepingCapacity: true)

            for property in element.properties {
                if property.isList {
                    guard let countType = property.listCountType else { throw SplatsError.invalidData }
                    let (listCount, countSize) = try readBinaryValue(from: bytes, at: offset, type: countType, littleEndian: littleEndian)
                    offset += countSize

                    let count: Int = switch listCount {
                    case .char(let v):
                        Int(v)
                    case .uchar(let v):
                        Int(v)
                    case .short(let v):
                        Int(v)
                    case .ushort(let v):
                        Int(v)
                    case .int(let v):
                        Int(v)
                    case .uint(let v):
                        Int(v)
                    default:
                        throw SplatsError.invalidData
                    }
                    var listValues: [PropertyValue] = []

                    for _ in 0..<count {
                        let (value, size) = try readBinaryValue(from: bytes, at: offset, type: property.listItemType ?? property.type, littleEndian: littleEndian)
                        listValues.append(value)
                        offset += size
                    }
                    rowValues.append(.list(listValues))
                } else {
                    let (value, size) = try readBinaryValue(from: bytes, at: offset, type: property.type, littleEndian: littleEndian)
                    rowValues.append(value)
                    offset += size
                }
            }

            try callback(rowValues)
        }
        }
    }

    /// Streams each record as Floats in header declaration order.
    ///
    /// List properties and unparsable ASCII scalars yield nil, matching
    /// ``PropertyValue/floatValue``. Avoids per-scalar enum allocation for
    /// numeric decoding.
    public func readFloatValues(element: Element, callback: ([Float?]) throws -> Void) throws {
        guard let format else {
            throw SplatsError.formatNotSet
        }

        switch format {
        case .ascii:
            try readASCIIFloats(element: element, callback: callback)

        case .binaryLittleEndian:
            try readBinaryFloats(element: element, littleEndian: true, callback: callback)

        case .binaryBigEndian:
            try readBinaryFloats(element: element, littleEndian: false, callback: callback)
        }
    }

    private func readASCIIFloats(element: Element, callback: ([Float?]) throws -> Void) throws {
        try readASCII(element: element) { values in
            try callback(values.map { $0?.floatValue })
        }
    }

    private func readBinaryFloats(element: Element, littleEndian: Bool, callback: ([Float?]) throws -> Void) throws {
        let data = self.data

        var offset = headerEndOffset
        for el in elements {
            if el.name == element.name {
                break
            }
            offset += el.count * el.properties.reduce(0) { sum, prop in
                sum + (prop.isList ? 0 : prop.type.size)
            }
        }

        var rowValues: [Float?] = []
        rowValues.reserveCapacity(element.properties.count)

        // The hot scalar loop iterates plain enums, not String-bearing
        // Property structs, to avoid retain traffic per scalar in Debug.
        if !element.properties.contains(where: \.isList) {
            let types = element.properties.map(\.type)
            try data.withUnsafeBytes { buffer in
                let bytes = RawSpan(_unsafeBytes: buffer)
                for _ in 0..<element.count {
                    rowValues.removeAll(keepingCapacity: true)
                    for type in types {
                        let (value, size) = try readBinaryFloat(from: bytes, at: offset, type: type, littleEndian: littleEndian)
                        rowValues.append(value)
                        offset += size
                    }
                    try callback(rowValues)
                }
            }
            return
        }

        try data.withUnsafeBytes { buffer in
            let bytes = RawSpan(_unsafeBytes: buffer)
            for _ in 0..<element.count {
                rowValues.removeAll(keepingCapacity: true)

                for property in element.properties {
                    if property.isList {
                        guard let countType = property.listCountType else { throw SplatsError.invalidData }
                        let (countValue, countSize) = try readBinaryFloat(from: bytes, at: offset, type: countType, littleEndian: littleEndian)
                        offset += countSize
                        let itemType = property.listItemType ?? property.type
                        let itemCount = Int(countValue)
                        guard itemCount >= 0, offset + itemCount * itemType.size <= bytes.byteCount else {
                            throw SplatsError.invalidData
                        }
                        offset += itemCount * itemType.size
                        rowValues.append(nil)
                    } else {
                        let (value, size) = try readBinaryFloat(from: bytes, at: offset, type: property.type, littleEndian: littleEndian)
                        rowValues.append(value)
                        offset += size
                    }
                }

                try callback(rowValues)
            }
        }
    }

    private func readBinaryFloat(from bytes: borrowing RawSpan, at offset: Int, type: PropertyType, littleEndian: Bool) throws -> (Float, Int) {
        guard offset + type.size <= bytes.byteCount else {
            throw SplatsError.invalidData
        }

        switch type {
        case .char:
            return (Float(Int8(bitPattern: bytes[offset])), 1)

        case .uchar:
            return (Float(bytes[offset]), 1)

        case .short:
            let value = bytes.load(fromByteOffset: offset, as: Int16.self)
            return (Float(littleEndian ? value : value.byteSwapped), 2)

        case .ushort:
            let value = bytes.load(fromByteOffset: offset, as: UInt16.self)
            return (Float(littleEndian ? value : value.byteSwapped), 2)

        case .int:
            let value = bytes.load(fromByteOffset: offset, as: Int32.self)
            return (Float(littleEndian ? value : value.byteSwapped), 4)

        case .uint:
            let value = bytes.load(fromByteOffset: offset, as: UInt32.self)
            return (Float(littleEndian ? value : value.byteSwapped), 4)

        case .float:
            let value = bytes.load(fromByteOffset: offset, as: UInt32.self)
            return (Float(bitPattern: littleEndian ? value : value.byteSwapped), 4)

        case .double:
            let value = bytes.load(fromByteOffset: offset, as: UInt64.self)
            return (Float(Double(bitPattern: littleEndian ? value : value.byteSwapped)), 8)
        }
    }

    private func readBinaryValue(from bytes: borrowing RawSpan, at offset: Int, type: PropertyType, littleEndian: Bool) throws -> (PropertyValue, Int) {
        guard offset + type.size <= bytes.byteCount else {
            throw SplatsError.invalidData
        }

        switch type {
        case .char:
            return (.char(Int8(bitPattern: bytes[offset])), 1)

        case .uchar:
            return (.uchar(bytes[offset]), 1)

        case .short:
            let value = bytes.load(fromByteOffset: offset, as: Int16.self)
            return (.short(littleEndian ? value : value.byteSwapped), 2)

        case .ushort:
            let value = bytes.load(fromByteOffset: offset, as: UInt16.self)
            return (.ushort(littleEndian ? value : value.byteSwapped), 2)

        case .int:
            let value = bytes.load(fromByteOffset: offset, as: Int32.self)
            return (.int(littleEndian ? value : value.byteSwapped), 4)

        case .uint:
            let value = bytes.load(fromByteOffset: offset, as: UInt32.self)
            return (.uint(littleEndian ? value : value.byteSwapped), 4)

        case .float:
            let value = bytes.load(fromByteOffset: offset, as: UInt32.self)
            let swapped = littleEndian ? value : value.byteSwapped
            return (.float(Float(bitPattern: swapped)), 4)

        case .double:
            let value = bytes.load(fromByteOffset: offset, as: UInt64.self)
            let swapped = littleEndian ? value : value.byteSwapped
            return (.double(Double(bitPattern: swapped)), 8)
        }
    }
}

public extension PLYReader.PropertyType {
    init?(string: String) {
        switch string {
        case "char", "int8":
            self = .char
        case "uchar", "uint8":
            self = .uchar
        case "short", "int16":
            self = .short
        case "ushort", "uint16":
            self = .ushort
        case "int", "int32":
            self = .int
        case "uint", "uint32":
            self = .uint
        case "float", "float32":
            self = .float
        case "double", "float64":
            self = .double
        default:
            return nil
        }
    }

    var size: Int {
        switch self {
        case .char, .uchar:
            return 1
        case .short, .ushort:
            return 2
        case .int, .uint, .float:
            return 4
        case .double:
            return 8
        }
    }
}

public extension PLYReader.PropertyValue {
    init?(string: String, type: PLYReader.PropertyType) {
        switch type {
        case .char:
            guard let v = Int8(string) else {
                return nil
            }
            self = .char(v)

        case .uchar:
            guard let v = UInt8(string) else {
                return nil
            }
            self = .uchar(v)

        case .short:
            guard let v = Int16(string) else {
                return nil
            }
            self = .short(v)

        case .ushort:
            guard let v = UInt16(string) else {
                return nil
            }
            self = .ushort(v)

        case .int:
            guard let v = Int32(string) else {
                return nil
            }
            self = .int(v)

        case .uint:
            guard let v = UInt32(string) else {
                return nil
            }
            self = .uint(v)

        case .float:
            guard let v = Float(string) else {
                return nil
            }
            self = .float(v)

        case .double:
            guard let v = Double(string) else {
                return nil
            }
            self = .double(v)
        }
    }

    var floatValue: Float? {
        switch self {
        case .char(let v):
            return Float(v)
        case .uchar(let v):
            return Float(v)
        case .short(let v):
            return Float(v)
        case .ushort(let v):
            return Float(v)
        case .int(let v):
            return Float(v)
        case .uint(let v):
            return Float(v)
        case .float(let v):
            return v
        case .double(let v):
            return Float(v)
        case .list:
            return nil
        }
    }
}

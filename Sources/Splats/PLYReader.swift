import Foundation
import UniformTypeIdentifiers

public extension UTType {
    static var ply: UTType {
        guard let type = UTType(filenameExtension: "ply") else {
            fatalError("Failed to create UTType for .ply extension")
        }
        return type
    }
}

public struct PLYReader {
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
            throw PLYError.invalidEncoding
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
                guard parts.count >= 2 else { throw PLYError.invalidHeader }
                switch parts[1] {
                case "ascii":
                    format = .ascii

                case "binary_little_endian":
                    format = .binaryLittleEndian

                case "binary_big_endian":
                    format = .binaryBigEndian

                default:
                    throw PLYError.unsupportedFormat(parts[1])
                }

            case "element":
                if let element = currentElement {
                    elements.append(Element(name: element.name, count: element.count, properties: element.properties))
                }

                guard parts.count >= 3, let count = Int(parts[2]) else {
                    throw PLYError.invalidHeader
                }
                currentElement = (name: parts[1], count: count, properties: [])

            case "property":
                guard var element = currentElement else { throw PLYError.invalidHeader }

                if parts[1] == "list" {
                    guard parts.count >= 5, let countType = PropertyType(string: parts[2]), let itemType = PropertyType(string: parts[3]) else {
                        throw PLYError.invalidHeader
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
                        throw PLYError.invalidHeader
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

        throw PLYError.missingEndHeader
    }

    public func read(_ callback: (Record) throws -> Void) throws {
        guard let element = primaryElement else {
            throw PLYError.noElements
        }
        try read(element: element, callback: callback)
    }

    public func read(element: Element, callback: (Record) throws -> Void) throws {
        guard let format else {
            throw PLYError.formatNotSet
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

    private func readASCII(element: Element, callback: (Record) throws -> Void) throws {
        guard let content = String(data: data, encoding: .utf8) else {
            throw PLYError.invalidEncoding
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
            var record: Record = [:]

            for property in element.properties {
                if property.isList {
                    guard valueIndex < values.count, let listCount = Int(values[valueIndex]) else {
                        throw PLYError.invalidData
                    }
                    valueIndex += 1

                    var listValues: [PropertyValue] = []
                    for _ in 0..<listCount {
                        guard valueIndex < values.count else { throw PLYError.invalidData }
                        if let value = PropertyValue(string: values[valueIndex], type: property.listItemType ?? property.type) {
                            listValues.append(value)
                        }
                        valueIndex += 1
                    }
                    record[property.name] = .list(listValues)
                } else {
                    guard valueIndex < values.count else { throw PLYError.invalidData }
                    if let value = PropertyValue(string: values[valueIndex], type: property.type) {
                        record[property.name] = value
                    }
                    valueIndex += 1
                }
            }

            try callback(record)
        }
    }

    private func readBinary(element: Element, littleEndian: Bool, callback: (Record) throws -> Void) throws {
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

        for _ in 0..<element.count {
            var record: Record = [:]

            for property in element.properties {
                if property.isList {
                    guard let countType = property.listCountType else { throw PLYError.invalidData }
                    let (listCount, countSize) = try readBinaryValue(from: data, at: offset, type: countType, littleEndian: littleEndian)
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
                        throw PLYError.invalidData
                    }
                    var listValues: [PropertyValue] = []

                    for _ in 0..<count {
                        let (value, size) = try readBinaryValue(from: data, at: offset, type: property.listItemType ?? property.type, littleEndian: littleEndian)
                        listValues.append(value)
                        offset += size
                    }
                    record[property.name] = .list(listValues)
                } else {
                    let (value, size) = try readBinaryValue(from: data, at: offset, type: property.type, littleEndian: littleEndian)
                    record[property.name] = value
                    offset += size
                }
            }

            try callback(record)
        }
    }

    private func readBinaryValue(from data: Data, at offset: Int, type: PropertyType, littleEndian: Bool) throws -> (PropertyValue, Int) {
        guard offset + type.size <= data.count else {
            throw PLYError.invalidData
        }

        let bytes = data[offset..<(offset + type.size)]

        switch type {
        case .char:
            return (.char(Int8(bitPattern: bytes[offset])), 1)

        case .uchar:
            return (.uchar(bytes[offset]), 1)

        case .short:
            let value: Int16 = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
            return (.short(littleEndian ? value : value.byteSwapped), 2)

        case .ushort:
            let value: UInt16 = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            return (.ushort(littleEndian ? value : value.byteSwapped), 2)

        case .int:
            let value: Int32 = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            return (.int(littleEndian ? value : value.byteSwapped), 4)

        case .uint:
            let value: UInt32 = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return (.uint(littleEndian ? value : value.byteSwapped), 4)

        case .float:
            let value: UInt32 = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let swapped = littleEndian ? value : value.byteSwapped
            return (.float(Float(bitPattern: swapped)), 4)

        case .double:
            let value: UInt64 = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            let swapped = littleEndian ? value : value.byteSwapped
            return (.double(Double(bitPattern: swapped)), 8)
        }
    }
}

public enum PLYError: Error, Equatable {
    case invalidEncoding
    case invalidHeader
    case unsupportedFormat(String)
    case missingEndHeader
    case noElements
    case formatNotSet
    case invalidData
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

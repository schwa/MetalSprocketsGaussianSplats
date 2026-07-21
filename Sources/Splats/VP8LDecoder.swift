import Foundation

// Pure-Swift lossless WebP (VP8L, RFC 9649) decoder.
//
// ImageIO on recent macOS rejects some valid VP8L streams (lossless WebP using
// the color-indexing transform with an alpha-carrying palette at large
// dimensions), which breaks loading SOG files from encoders that emit such
// textures (issue #71). This decoder is used as a fallback when
// CGImageSourceCreateImageAtIndex fails. Lossy (VP8) WebP is not supported.

enum VP8LError: Error, Equatable {
    case notWebP
    case noVP8LChunk
    case truncated
    case invalidFormat(String)
}

enum VP8LDecoder {
    /// Decodes a WebP file containing a VP8L (lossless) bitstream to
    /// non-premultiplied RGBA8 bytes in scan-line order.
    static func decodeRGBA(_ data: Data) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let stream = try vp8lChunk(in: data)
        var decoder = Decoder(data: stream)
        let (argb, width, height) = try decoder.decode()
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0 ..< argb.count {
            let p = argb[i]
            rgba[i * 4 + 0] = UInt8((p >> 16) & 0xFF)
            rgba[i * 4 + 1] = UInt8((p >> 8) & 0xFF)
            rgba[i * 4 + 2] = UInt8(p & 0xFF)
            rgba[i * 4 + 3] = UInt8(p >> 24)
        }
        return (rgba, width, height)
    }

    /// Extracts the VP8L chunk payload from a RIFF/WEBP container.
    private static func vp8lChunk(in data: Data) throws -> [UInt8] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0...3].elementsEqual("RIFF".utf8), bytes[8...11].elementsEqual("WEBP".utf8) else {
            throw VP8LError.notWebP
        }
        var offset = 12
        while offset + 8 <= bytes.count {
            let fourCC = bytes[offset ..< offset + 4]
            let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            let payloadStart = offset + 8
            guard size >= 0, payloadStart + size <= bytes.count else {
                throw VP8LError.truncated
            }
            if fourCC.elementsEqual("VP8L".utf8) {
                return Array(bytes[payloadStart ..< payloadStart + size])
            }
            offset = payloadStart + size + (size & 1)
        }
        throw VP8LError.noVP8LChunk
    }
}

// MARK: - Bit reader

private struct BitReader {
    let data: [UInt8]
    var position = 0 // Bit offset from the start.

    mutating func readBits(_ count: Int) throws -> Int {
        var value = 0
        for i in 0 ..< count {
            let byteIndex = position >> 3
            guard byteIndex < data.count else {
                throw VP8LError.truncated
            }
            let bit = (Int(data[byteIndex]) >> (position & 7)) & 1
            value |= bit << i
            position += 1
        }
        return value
    }

    mutating func readBit() throws -> Int {
        try readBits(1)
    }
}

// MARK: - Prefix (Huffman) codes

private struct PrefixCode {
    /// Non-nil when the code has a single symbol; decoding consumes no bits.
    let singleSymbol: Int?
    /// Symbols sorted by (code length, symbol), lengths ascending.
    let symbols: [Int]
    /// count[len] = number of symbols with that code length.
    let counts: [Int]

    init(codeLengths: [Int]) throws {
        let maxLength = codeLengths.max() ?? 0
        let used = codeLengths.enumerated().filter { $0.element > 0 }
        if used.count <= 1 {
            singleSymbol = used.first?.offset ?? 0
            symbols = []
            counts = []
            return
        }
        singleSymbol = nil
        var counts = [Int](repeating: 0, count: maxLength + 1)
        for length in codeLengths where length > 0 {
            counts[length] += 1
        }
        symbols = used.sorted { ($0.element, $0.offset) < ($1.element, $1.offset) }.map(\.offset)
        self.counts = counts
    }

    func decode(_ reader: inout BitReader) throws -> Int {
        if let singleSymbol {
            return singleSymbol
        }
        var code = 0
        var first = 0
        var index = 0
        for length in 1 ..< counts.count {
            code = code << 1 | (try reader.readBit())
            let count = counts[length]
            if code - first < count {
                return symbols[index + code - first]
            }
            index += count
            first = (first + count) << 1
        }
        throw VP8LError.invalidFormat("invalid prefix code")
    }
}

// MARK: - Decoder

private struct Decoder {
    var reader: BitReader

    init(data: [UInt8]) {
        reader = BitReader(data: data)
    }

    private static let codeLengthCodeOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    /// Distance codes 1...120 map to a 2D neighborhood (RFC 9649 figure 20).
    private static let distanceMap: [(x: Int, y: Int)] = [
        (0, 1), (1, 0), (1, 1), (-1, 1), (0, 2), (2, 0), (1, 2),
        (-1, 2), (2, 1), (-2, 1), (2, 2), (-2, 2), (0, 3), (3, 0),
        (1, 3), (-1, 3), (3, 1), (-3, 1), (2, 3), (-2, 3), (3, 2),
        (-3, 2), (0, 4), (4, 0), (1, 4), (-1, 4), (4, 1), (-4, 1),
        (3, 3), (-3, 3), (2, 4), (-2, 4), (4, 2), (-4, 2), (0, 5),
        (3, 4), (-3, 4), (4, 3), (-4, 3), (5, 0), (1, 5), (-1, 5),
        (5, 1), (-5, 1), (2, 5), (-2, 5), (5, 2), (-5, 2), (4, 4),
        (-4, 4), (3, 5), (-3, 5), (5, 3), (-5, 3), (0, 6), (6, 0),
        (1, 6), (-1, 6), (6, 1), (-6, 1), (2, 6), (-2, 6), (6, 2),
        (-6, 2), (4, 5), (-4, 5), (5, 4), (-5, 4), (3, 6), (-3, 6),
        (6, 3), (-6, 3), (0, 7), (7, 0), (1, 7), (-1, 7), (5, 5),
        (-5, 5), (7, 1), (-7, 1), (4, 6), (-4, 6), (6, 4), (-6, 4),
        (2, 7), (-2, 7), (7, 2), (-7, 2), (3, 7), (-3, 7), (7, 3),
        (-7, 3), (5, 6), (-5, 6), (6, 5), (-6, 5), (8, 0), (4, 7),
        (-4, 7), (7, 4), (-7, 4), (8, 1), (8, 2), (6, 6), (-6, 6),
        (8, 3), (5, 7), (-5, 7), (7, 5), (-7, 5), (8, 4), (6, 7),
        (-6, 7), (7, 6), (-7, 6), (8, 5), (7, 7), (-7, 7), (8, 6),
        (8, 7)
    ]

    private enum Transform {
        case predictor(sizeBits: Int, width: Int, height: Int, data: [UInt32])
        case color(sizeBits: Int, width: Int, data: [UInt32])
        case subtractGreen
        case colorIndexing(originalWidth: Int, widthBits: Int, palette: [UInt32])
    }

    mutating func decode() throws -> (pixels: [UInt32], width: Int, height: Int) {
        guard try reader.readBits(8) == 0x2F else {
            throw VP8LError.invalidFormat("bad VP8L signature")
        }
        let width = try reader.readBits(14) + 1
        let height = try reader.readBits(14) + 1
        _ = try reader.readBit() // alpha-is-used hint
        guard try reader.readBits(3) == 0 else {
            throw VP8LError.invalidFormat("unsupported VP8L version")
        }

        var xsize = width
        var transforms: [Transform] = []
        while try reader.readBit() == 1 {
            let type = try reader.readBits(2)
            switch type {
            case 0: // Predictor
                let sizeBits = try reader.readBits(3) + 2
                let data = try decodeImageData(width: subSampleSize(xsize, sizeBits), height: subSampleSize(height, sizeBits), isLevel0: false)
                transforms.append(.predictor(sizeBits: sizeBits, width: xsize, height: height, data: data))

            case 1: // Color
                let sizeBits = try reader.readBits(3) + 2
                let data = try decodeImageData(width: subSampleSize(xsize, sizeBits), height: subSampleSize(height, sizeBits), isLevel0: false)
                transforms.append(.color(sizeBits: sizeBits, width: xsize, data: data))

            case 2: // Subtract green
                transforms.append(.subtractGreen)

            case 3: // Color indexing
                let tableSize = try reader.readBits(8) + 1
                var palette = try decodeImageData(width: tableSize, height: 1, isLevel0: false)
                for i in 1 ..< palette.count {
                    // Palette entries are delta coded per channel.
                    let previous = palette[i - 1]
                    let current = palette[i]
                    let sum = ((current & 0xFF00_FF00) &+ (previous & 0xFF00_FF00)) & 0xFF00_FF00
                        | ((current & 0x00FF_00FF) &+ (previous & 0x00FF_00FF)) & 0x00FF_00FF
                    palette[i] = sum
                }
                let widthBits: Int
                switch tableSize {
                case ...2:
                    widthBits = 3
                case ...4:
                    widthBits = 2
                case ...16:
                    widthBits = 1
                default:
                    widthBits = 0
                }
                transforms.append(.colorIndexing(originalWidth: xsize, widthBits: widthBits, palette: palette))
                xsize = subSampleSize(xsize, widthBits)

            default:
                throw VP8LError.invalidFormat("bad transform type")
            }
        }

        var pixels = try decodeImageData(width: xsize, height: height, isLevel0: true)
        var currentWidth = xsize
        for transform in transforms.reversed() {
            switch transform {
            case let .colorIndexing(originalWidth, widthBits, palette):
                pixels = Self.applyInverseColorIndexing(pixels, reducedWidth: currentWidth, width: originalWidth, height: height, widthBits: widthBits, palette: palette)
                currentWidth = originalWidth

            case let .predictor(sizeBits, width, height, data):
                Self.applyInversePredictor(&pixels, width: width, height: height, sizeBits: sizeBits, blocks: data)

            case let .color(sizeBits, width, data):
                Self.applyInverseColorTransform(&pixels, width: width, sizeBits: sizeBits, blocks: data)

            case .subtractGreen:
                for i in 0 ..< pixels.count {
                    let green = (pixels[i] >> 8) & 0xFF
                    let red = ((pixels[i] >> 16) &+ green) & 0xFF
                    let blue = (pixels[i] &+ green) & 0xFF
                    pixels[i] = pixels[i] & 0xFF00_FF00 | red << 16 | blue
                }
            }
        }
        guard currentWidth == width, pixels.count == width * height else {
            throw VP8LError.invalidFormat("size mismatch after inverse transforms")
        }
        return (pixels, width, height)
    }

    private func subSampleSize(_ size: Int, _ bits: Int) -> Int {
        (size + (1 << bits) - 1) >> bits
    }

    // MARK: Entropy-coded image

    private mutating func decodeImageData(width: Int, height: Int, isLevel0: Bool) throws -> [UInt32] {
        var cacheBits = 0
        if try reader.readBit() == 1 {
            cacheBits = try reader.readBits(4)
            guard (1...11).contains(cacheBits) else {
                throw VP8LError.invalidFormat("bad color cache size")
            }
        }
        let cacheSize = cacheBits > 0 ? 1 << cacheBits : 0

        var metaBits = 0
        var metaImage: [UInt32] = []
        var metaWidth = 0
        var groupCount = 1
        if isLevel0, try reader.readBit() == 1 {
            metaBits = try reader.readBits(3) + 2
            metaWidth = subSampleSize(width, metaBits)
            metaImage = try decodeImageData(width: metaWidth, height: subSampleSize(height, metaBits), isLevel0: false)
            groupCount = Int(metaImage.map { ($0 >> 8) & 0xFFFF }.max() ?? 0) + 1
        }

        let greenAlphabet = 256 + 24 + cacheSize
        let alphabets = [greenAlphabet, 256, 256, 256, 40]
        var groups: [[PrefixCode]] = []
        groups.reserveCapacity(groupCount)
        for _ in 0 ..< groupCount {
            var codes: [PrefixCode] = []
            for alphabet in alphabets {
                codes.append(try PrefixCode(codeLengths: try readCodeLengths(alphabetSize: alphabet)))
            }
            groups.append(codes)
        }

        var cache = [UInt32](repeating: 0, count: cacheSize)
        let cacheShift = 32 - cacheBits
        func cacheInsert(_ pixel: UInt32) {
            if cacheSize > 0 {
                cache[Int((0x1E35_A7BD &* pixel) >> UInt32(cacheShift))] = pixel
            }
        }

        var pixels = [UInt32](repeating: 0, count: width * height)
        var index = 0
        let total = width * height
        while index < total {
            let x = index % width
            let y = index / width
            let group: [PrefixCode]
            if metaImage.isEmpty {
                group = groups[0]
            } else {
                let meta = Int((metaImage[(y >> metaBits) * metaWidth + (x >> metaBits)] >> 8) & 0xFFFF)
                group = groups[meta]
            }

            let symbol = try group[0].decode(&reader)
            if symbol < 256 {
                let green = UInt32(symbol)
                let red = UInt32(try group[1].decode(&reader))
                let blue = UInt32(try group[2].decode(&reader))
                let alpha = UInt32(try group[3].decode(&reader))
                let pixel = alpha << 24 | red << 16 | green << 8 | blue
                pixels[index] = pixel
                cacheInsert(pixel)
                index += 1
            } else if symbol < 256 + 24 {
                let length = try readPrefixValue(symbol - 256)
                let distanceCode = try readPrefixValue(try group[4].decode(&reader))
                let distance = planeCodeToDistance(distanceCode, width: width)
                guard distance <= index, index + length <= total else {
                    throw VP8LError.invalidFormat("bad backward reference")
                }
                for _ in 0 ..< length {
                    let pixel = pixels[index - distance]
                    pixels[index] = pixel
                    cacheInsert(pixel)
                    index += 1
                }
            } else {
                let cacheIndex = symbol - 256 - 24
                guard cacheIndex < cacheSize else {
                    throw VP8LError.invalidFormat("bad color cache index")
                }
                pixels[index] = cache[cacheIndex]
                index += 1
            }
        }
        return pixels
    }

    private mutating func readPrefixValue(_ prefixCode: Int) throws -> Int {
        if prefixCode < 4 {
            return prefixCode + 1
        }
        let extraBits = (prefixCode - 2) >> 1
        let offset = (2 + (prefixCode & 1)) << extraBits
        return offset + (try reader.readBits(extraBits)) + 1
    }

    private func planeCodeToDistance(_ code: Int, width: Int) -> Int {
        if code > 120 {
            return code - 120
        }
        let (x, y) = Self.distanceMap[code - 1]
        return max(1, x + y * width)
    }

    // MARK: Code length reading

    private mutating func readCodeLengths(alphabetSize: Int) throws -> [Int] {
        var lengths = [Int](repeating: 0, count: alphabetSize)
        if try reader.readBit() == 1 { // Simple code
            let symbolCount = try reader.readBit() + 1
            let firstIs8Bits = try reader.readBit()
            let symbol0 = try reader.readBits(firstIs8Bits == 1 ? 8 : 1)
            guard symbol0 < alphabetSize else {
                throw VP8LError.invalidFormat("simple code symbol out of range")
            }
            lengths[symbol0] = 1
            if symbolCount == 2 {
                let symbol1 = try reader.readBits(8)
                guard symbol1 < alphabetSize else {
                    throw VP8LError.invalidFormat("simple code symbol out of range")
                }
                lengths[symbol1] = 1
            }
            return lengths
        }

        var codeLengthCodeLengths = [Int](repeating: 0, count: 19)
        let codeLengthCount = 4 + (try reader.readBits(4))
        for i in 0 ..< codeLengthCount {
            codeLengthCodeLengths[Self.codeLengthCodeOrder[i]] = try reader.readBits(3)
        }
        let codeLengthCode = try PrefixCode(codeLengths: codeLengthCodeLengths)

        var maxSymbol = alphabetSize
        if try reader.readBit() == 1 {
            let lengthBitCount = 2 + 2 * (try reader.readBits(3))
            maxSymbol = 2 + (try reader.readBits(lengthBitCount))
            guard maxSymbol <= alphabetSize else {
                throw VP8LError.invalidFormat("max_symbol exceeds alphabet")
            }
        }

        var symbol = 0
        var previousLength = 8
        while symbol < alphabetSize {
            if maxSymbol == 0 {
                break
            }
            maxSymbol -= 1
            let code = try codeLengthCode.decode(&reader)
            switch code {
            case 0 ..< 16:
                lengths[symbol] = code
                symbol += 1
                if code != 0 {
                    previousLength = code
                }

            case 16, 17, 18:
                let repeatCount: Int
                let fill: Int
                switch code {
                case 16:
                    repeatCount = 3 + (try reader.readBits(2))
                    fill = previousLength
                case 17:
                    repeatCount = 3 + (try reader.readBits(3))
                    fill = 0
                default:
                    repeatCount = 11 + (try reader.readBits(7))
                    fill = 0
                }
                guard symbol + repeatCount <= alphabetSize else {
                    throw VP8LError.invalidFormat("code length repeat overflows alphabet")
                }
                for _ in 0 ..< repeatCount {
                    lengths[symbol] = fill
                    symbol += 1
                }

            default:
                throw VP8LError.invalidFormat("bad code length code")
            }
        }
        return lengths
    }

    // MARK: Inverse transforms

    private static func applyInverseColorIndexing(_ pixels: [UInt32], reducedWidth: Int, width: Int, height: Int, widthBits: Int, palette: [UInt32]) -> [UInt32] {
        if widthBits == 0 {
            return pixels.map { pixel in
                let index = Int((pixel >> 8) & 0xFF)
                return index < palette.count ? palette[index] : 0
            }
        }
        let pixelsPerPacked = 1 << widthBits
        let bitsPerPixel = 8 >> widthBits
        let mask = (1 << bitsPerPixel) - 1
        var output = [UInt32](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let packed = Int((pixels[y * reducedWidth + (x >> widthBits)] >> 8) & 0xFF)
                let index = (packed >> ((x % pixelsPerPacked) * bitsPerPixel)) & mask
                output[y * width + x] = index < palette.count ? palette[index] : 0
            }
        }
        return output
    }

    private static func applyInversePredictor(_ pixels: inout [UInt32], width: Int, height: Int, sizeBits: Int, blocks: [UInt32]) {
        let blocksPerRow = (width + (1 << sizeBits) - 1) >> sizeBits

        func average2(_ a: UInt32, _ b: UInt32) -> UInt32 {
            (((a ^ b) & 0xFEFE_FEFE) >> 1) &+ (a & b)
        }
        func clamp255(_ value: Int) -> UInt32 {
            UInt32(min(255, max(0, value)))
        }
        func byte(_ pixel: UInt32, _ shift: Int) -> Int {
            Int((pixel >> UInt32(shift)) & 0xFF)
        }

        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x
                let predicted: UInt32
                if x == 0, y == 0 {
                    predicted = 0xFF00_0000
                } else if y == 0 {
                    predicted = pixels[index - 1]
                } else if x == 0 {
                    predicted = pixels[index - width]
                } else {
                    let left = pixels[index - 1]
                    let top = pixels[index - width]
                    let topLeft = pixels[index - width - 1]
                    // For the rightmost column this reads the current row's
                    // leftmost (already decoded) pixel, per the spec.
                    let topRight = pixels[index - width + 1]
                    let mode = (blocks[(y >> sizeBits) * blocksPerRow + (x >> sizeBits)] >> 8) & 0xFF
                    switch mode {
                    case 0:
                        predicted = 0xFF00_0000
                    case 1:
                        predicted = left
                    case 2:
                        predicted = top
                    case 3:
                        predicted = topRight
                    case 4:
                        predicted = topLeft
                    case 5:
                        predicted = average2(average2(left, topRight), top)
                    case 6:
                        predicted = average2(left, topLeft)
                    case 7:
                        predicted = average2(left, top)
                    case 8:
                        predicted = average2(topLeft, top)
                    case 9:
                        predicted = average2(top, topRight)
                    case 10:
                        predicted = average2(average2(left, topLeft), average2(top, topRight))
                    case 11:
                        var pLeft = 0
                        var pTop = 0
                        for shift in [24, 16, 8, 0] {
                            let estimate = byte(left, shift) + byte(top, shift) - byte(topLeft, shift)
                            pLeft += abs(estimate - byte(left, shift))
                            pTop += abs(estimate - byte(top, shift))
                        }
                        predicted = pLeft < pTop ? left : top
                    case 12:
                        var value: UInt32 = 0
                        for shift in [24, 16, 8, 0] {
                            value |= clamp255(byte(left, shift) + byte(top, shift) - byte(topLeft, shift)) << UInt32(shift)
                        }
                        predicted = value
                    case 13:
                        let average = average2(left, top)
                        var value: UInt32 = 0
                        for shift in [24, 16, 8, 0] {
                            let a = byte(average, shift)
                            value |= clamp255(a + (a - byte(topLeft, shift)) / 2) << UInt32(shift)
                        }
                        predicted = value
                    default:
                        predicted = 0xFF00_0000
                    }
                }
                let residual = pixels[index]
                // Per-channel wrapping add of residual and prediction.
                pixels[index] = ((residual & 0xFF00_FF00) &+ (predicted & 0xFF00_FF00)) & 0xFF00_FF00
                    | ((residual & 0x00FF_00FF) &+ (predicted & 0x00FF_00FF)) & 0x00FF_00FF
            }
        }
    }

    private static func applyInverseColorTransform(_ pixels: inout [UInt32], width: Int, sizeBits: Int, blocks: [UInt32]) {
        let blocksPerRow = (width + (1 << sizeBits) - 1) >> sizeBits

        func delta(_ transform: UInt32, _ channel: UInt32) -> Int {
            let t = Int(Int8(truncatingIfNeeded: Int(transform)))
            let c = Int(Int8(truncatingIfNeeded: Int(channel)))
            return (t * c) >> 5
        }

        let height = pixels.count / width
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x
                let element = blocks[(y >> sizeBits) * blocksPerRow + (x >> sizeBits)]
                let greenToRed = element & 0xFF
                let greenToBlue = (element >> 8) & 0xFF
                let redToBlue = (element >> 16) & 0xFF
                let pixel = pixels[index]
                let green = (pixel >> 8) & 0xFF
                var red = Int((pixel >> 16) & 0xFF)
                var blue = Int(pixel & 0xFF)
                red += delta(greenToRed, green)
                red &= 0xFF
                blue += delta(greenToBlue, green)
                blue += delta(redToBlue, UInt32(red))
                blue &= 0xFF
                pixels[index] = pixel & 0xFF00_FF00 | UInt32(red) << 16 | UInt32(blue)
            }
        }
    }
}

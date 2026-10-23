import CoreGraphics
import Foundation
import ImageIO

/// Decodes a SOG texture (WebP) to raw, non-premultiplied RGBA8 bytes.
///
/// The decoder tries ImageIO first. ImageIO rejects some valid lossless WebP
/// streams (issue #71). These use a VP8L color-indexing transform with an
/// alpha-carrying palette at large dimensions. On failure, the decoder falls
/// back to the pure-Swift ``VP8LDecoder``.
enum SOGImageDecode {
    static func decodeRGBA(_ imageData: Data, filename: String) throws -> (pixels: [UInt8], width: Int, height: Int) {
        if let result = decodeViaImageIO(imageData) {
            return result
        }
        do {
            return try VP8LDecoder.decodeRGBA(imageData)
        } catch {
            throw SplatsError.failedToDecodeImage(filename)
        }
    }

    private static func decodeViaImageIO(_ imageData: Data) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil), let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height

        if let pixels = straightRGBA8Bytes(cgImage) {
            return (pixels, width, height)
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // CGContext supports only premultiplied (or skip) alpha for 8-bit RGBA.
        // Draw premultiplied, then un-premultiply to recover the original
        // quantized bytes.
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[i + 3]
            if a > 0, a < 255 {
                let alphaF = Float(a) / 255.0
                pixels[i + 0] = UInt8(min(255, Float(pixels[i + 0]) / alphaF))
                pixels[i + 1] = UInt8(min(255, Float(pixels[i + 1]) / alphaF))
                pixels[i + 2] = UInt8(min(255, Float(pixels[i + 2]) / alphaF))
            }
        }
        return (pixels, width, height)
    }

    // ImageIO usually decodes WebP as straight-alpha RGBA8. Copying those bytes
    // avoids a premultiplied draw, which loses color precision at low alpha.
    private static func straightRGBA8Bytes(_ cgImage: CGImage) -> [UInt8]? {
        let byteOrder = cgImage.bitmapInfo.intersection(.byteOrderMask)
        guard cgImage.bitsPerComponent == 8,
              cgImage.bitsPerPixel == 32,
              cgImage.alphaInfo == .last,
              byteOrder == [] || byteOrder == .byteOrder32Big,
              !cgImage.bitmapInfo.contains(.floatComponents),
              cgImage.colorSpace?.model == .rgb,
              let data = cgImage.dataProvider?.data,
              let source = CFDataGetBytePtr(data) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        let sourceBytesPerRow = cgImage.bytesPerRow
        let rowBytes = width * 4
        guard sourceBytesPerRow >= rowBytes, CFDataGetLength(data) >= sourceBytesPerRow * (height - 1) + rowBytes else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else {
                return
            }
            if sourceBytesPerRow == rowBytes {
                base.copyMemory(from: source, byteCount: rowBytes * height)
            } else {
                for row in 0..<height {
                    (base + row * rowBytes).copyMemory(from: source + row * sourceBytesPerRow, byteCount: rowBytes)
                }
            }
        }
        return pixels
    }
}

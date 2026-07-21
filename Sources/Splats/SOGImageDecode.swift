import CoreGraphics
import Foundation
import ImageIO

/// Decodes a SOG texture (WebP) to raw, non-premultiplied RGBA8 bytes.
///
/// Tries ImageIO first. ImageIO rejects some valid lossless WebP streams
/// (VP8L color-indexing transform with an alpha-carrying palette at large
/// dimensions — issue #71), so on failure this falls back to the pure-Swift
/// ``VP8LDecoder``.
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

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // CGContext only supports premultiplied (or skip) alpha for 8-bit RGBA,
        // so we draw premultiplied then un-premultiply to recover the original
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
}

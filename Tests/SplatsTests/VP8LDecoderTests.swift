import Foundation
@testable import Splats
import Testing

/// Regression tests for the pure-Swift VP8L fallback decoder (issue #71).
///
/// `cwebp -lossless -q 100 -exact` produced the fixtures. The `.pam` reference
/// outputs come from `dwebp -pam` (libwebp's own decoder).
@Suite
struct VP8LDecoderTests {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/webp"))
        return try Data(contentsOf: url)
    }

    /// Parses a binary PAM (P7, RGB_ALPHA, 8-bit) file.
    private func parsePAM(_ data: Data) throws -> (pixels: [UInt8], width: Int, height: Int) {
        guard let headerEnd = data.range(of: Data("ENDHDR\n".utf8)) else {
            throw VP8LError.invalidFormat("bad PAM")
        }
        let header = try #require(String(bytes: data[..<headerEnd.lowerBound], encoding: .utf8))
        var width = 0
        var height = 0
        for line in header.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[0] == "WIDTH" { width = Int(parts[1]) ?? 0 }
            if parts.count == 2, parts[0] == "HEIGHT" { height = Int(parts[1]) ?? 0 }
        }
        return ([UInt8](data[headerEnd.upperBound...]), width, height)
    }

    private func expectMatchesReference(_ name: String) throws {
        let (pixels, width, height) = try VP8LDecoder.decodeRGBA(try fixture(name, "webp"))
        let reference = try parsePAM(try fixture(name, "pam"))
        #expect(width == reference.width)
        #expect(height == reference.height)
        #expect(pixels == reference.pixels)
    }

    @Test
    func photoLikeImage() throws {
        // Exercises predictor/color transforms, subtract-green, and color cache.
        try expectMatchesReference("photo")
    }

    @Test
    func smallPaletteWithAlpha() throws {
        // <=16 colors: color-indexing transform with pixel bundling.
        try expectMatchesReference("palette-small")
    }

    @Test
    func largePaletteWithAlpha() throws {
        // 17..256 colors: color-indexing transform without bundling.
        try expectMatchesReference("palette-large")
    }

    /// The ImageIO-failing shape from issue #71: a large (4200x4200) lossless
    /// WebP with an alpha-carrying palette. `SOGImageDecode` must decode it
    /// via the VP8L fallback even when CGImageSource rejects it.
    @Test
    func largePaletteAlphaImageThatImageIORejects() throws {
        let data = try fixture("big-const", "webp")
        let (pixels, width, height) = try SOGImageDecode.decodeRGBA(data, filename: "big-const.webp")
        #expect(width == 4_200)
        #expect(height == 4_200)
        #expect(pixels.count == 4_200 * 4_200 * 4)
        // The color is constant (77, 88, 99, 128) everywhere. Spot-check the corners and center.
        for index in [0, (4_200 * 4_200) / 2, 4_200 * 4_200 - 1] {
            #expect(pixels[index * 4 + 0] == 77)
            #expect(pixels[index * 4 + 1] == 88)
            #expect(pixels[index * 4 + 2] == 99)
            #expect(pixels[index * 4 + 3] == 128)
        }
    }
}

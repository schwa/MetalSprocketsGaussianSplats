#if !arch(x86_64)
import CoreGraphics
import GeometryLite3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Splats
import Testing

struct GeneratedSplatCloudTests {
    let device = MTLCreateSystemDefaultDevice()!

    @Test(arguments: [UInt8(1), 2, 3])
    func packsSphericalHarmonics(degree: UInt8) throws {
        let basisCount = (Int(degree) + 1) * (Int(degree) + 1) - 1
        let rows = (0..<basisCount).map { [Float($0), Float($0) + 0.25, Float($0) + 0.5] }
        let generic = GenericSplat(position: [1, 2, 3], scale: [0.1, 0.2, 0.3], color: [1, 0.5, 0.25, 0.75])
        let splat = ExtendedSplat(genericSplat: generic, sphericalHarmonics: rows)
        let transform = simd_float4x4(translation: [4, 5, 6])
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: [splat, splat], shDegree: degree, modelTransform: transform, opacity: 0.5, name: "Generated")
        #expect(cloud.count == 2)
        #expect(cloud.splats[0].position == SparkSplat(generic).position)
        #expect(cloud.splats[0].color == SparkSplat(generic).color)
        #expect(cloud.shDegree == degree)
        #expect(cloud.modelTransform == transform)
        #expect(cloud.opacity == 0.5)
        let coefficients = try #require(cloud.shCoefficients)
        #expect(Array(coefficients) == (rows + rows).flatMap(\.self))
        #expect(coefficients.unsafeMTLBuffer.label == "SHCoefficients (Generated)")
    }

    @Test
    func noSphericalHarmonics() throws {
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: [ExtendedSplat(genericSplat: GenericSplat())])
        #expect(cloud.count == 1)
        #expect(cloud.shDegree == 0)
        #expect(cloud.shCoefficients == nil)
    }

    @Test(arguments: [UInt8(0), 1, 2, 3])
    func emptyCloud(degree: UInt8) throws {
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: [ExtendedSplat](), shDegree: degree, mortonOrdered: true)
        #expect(cloud.splats.isEmpty)
        #expect(cloud.shCoefficients?.count ?? 0 == 0)
    }

    @Test
    func rejectsUnsupportedDegree() throws {
        #expect(throws: GPUSplatCloudError.unsupportedSphericalHarmonicsDegree(4)) {
            try GPUSplatCloud<SparkSplat>(device: device, splats: [ExtendedSplat](), shDegree: 4)
        }
    }

    @Test
    func rejectsMissingOrMalformedRows() throws {
        for rows: [[Float]]? in [nil, [], [[1, 2, 3]], [[1, 2], [1, 2, 3], [1, 2, 3]]] {
            let splat = ExtendedSplat(genericSplat: GenericSplat(), sphericalHarmonics: rows)
            #expect(throws: GPUSplatCloudError.self) {
                try GPUSplatCloud<SparkSplat>(device: device, splats: [splat], shDegree: 1)
            }
        }
    }

    @Test
    func mortonOrderingPreservesCoefficients() throws {
        let splats = [Float(3), -3, 1].map { position in
            ExtendedSplat(genericSplat: GenericSplat(position: [position, 0, 0]), sphericalHarmonics: Array(repeating: [position, position, position], count: 3))
        }
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: splats, shDegree: 1, mortonOrdered: true)
        let coefficients = try #require(cloud.shCoefficients)
        #expect(cloud.count == 3)
        for index in 0..<cloud.count {
            let position = Float(cloud.splats[index].position.x)
            #expect(Array(coefficients[(index * 9)..<((index + 1) * 9)]) == Array(repeating: position, count: 9))
        }
    }

    @Test
    @MainActor
    func indexedPaletteRendersLikeDense() throws {
        // Two palette rows shared by four splats (indices 0,1,1,0).
        let rowA: [Float] = [0.4, 0.1, 0.1, 0.4, 0.1, 0.1, 0.4, 0.1, 0.1]
        let rowB: [Float] = [0.1, 0.1, 0.4, 0.1, 0.1, 0.4, 0.1, 0.1, 0.4]
        let palette = rowA + rowB
        let indices: [UInt32] = [0, 1, 1, 0]
        let positions: [SIMD3<Float>] = [[-0.3, 0.3, 0], [0.3, 0.3, 0], [-0.3, -0.3, 0], [0.3, -0.3, 0]]
        let splats = positions.map { ExtendedSplat(genericSplat: GenericSplat(position: $0, scale: [0.3, 0.3, 0.3], color: [0.5, 0.5, 0.5, 1])) }

        let indexed = try GPUSplatCloud<SparkSplat>(device: device, splats: splats, shPalette: palette, shIndices: indices, shDegree: 1)
        let indexedCoefficients = try #require(indexed.shCoefficients)
        #expect(indexedCoefficients.count == palette.count) // palette-sized, not count-sized
        #expect(indexed.splats.map { $0.shIndex } == indices) // swiftlint:disable:this prefer_key_path

        // Dense equivalent: each splat carries its palette row expanded.
        let denseSplats = zip(splats, indices).map { splat, index in
            let rows: [[Float]] = index == 0 ? [[0.4, 0.1, 0.1], [0.4, 0.1, 0.1], [0.4, 0.1, 0.1]] : [[0.1, 0.1, 0.4], [0.1, 0.1, 0.4], [0.1, 0.1, 0.4]]
            return ExtendedSplat(genericSplat: splat.genericSplat, sphericalHarmonics: rows)
        }
        let dense = try GPUSplatCloud<SparkSplat>(device: device, splats: denseSplats, shDegree: 1)
        #expect(try #require(dense.shCoefficients).count == splats.count * 9)

        let camera = simd_float4x4(translation: [0, 0, 2])
        let projection = PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01 ... 100))
        let indexedImage = try render(indexed, camera: camera, projection: projection)
        let denseImage = try render(dense, camera: camera, projection: projection)
        #expect(indexedImage == denseImage)
    }

    @Test
    func indexedPaletteRejectsBadInput() throws {
        let splats = [ExtendedSplat(genericSplat: GenericSplat())]
        #expect(throws: GPUSplatCloudError.self) {
            try GPUSplatCloud<SparkSplat>(device: device, splats: splats, shPalette: [0, 0, 0], shIndices: [5], shDegree: 1)
        }
    }

    @MainActor
    private func render(_ cloud: GPUSplatCloud<SparkSplat>, camera: simd_float4x4, projection: PerspectiveProjection) throws -> [UInt8] {
        let renderer = try OffscreenSplatRenderer(renderer: .spark, splatCloud: cloud, projection: projection, cameraMatrix: camera, configuration: .init(width: 64, height: 64))
        try renderer.renderFrame()
        let image = try renderer.makeImage()
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}
#endif

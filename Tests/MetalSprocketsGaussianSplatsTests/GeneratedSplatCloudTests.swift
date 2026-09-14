#if !arch(x86_64)
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
}
#endif

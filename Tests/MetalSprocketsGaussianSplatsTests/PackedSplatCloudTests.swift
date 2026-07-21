#if !arch(x86_64)
import GeometryLite3D
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Testing

/// Seeded RNG so test clouds are identical across runs.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("PackedSplatCloud")
struct PackedSplatCloudTests {
    enum TestError: Error {
        case noMetalDevice
        case bufferAllocationFailed
    }

    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noMetalDevice
        }
        self.device = device
    }

    private static func randomSplats(count: Int, seed: UInt64) -> [SparkSplat] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in
            let position = SIMD3<Float>(Float.random(in: -2...2, using: &generator), Float.random(in: -2...2, using: &generator), Float.random(in: -2...2, using: &generator))
            let scale = SIMD3<Float>(exp(Float.random(in: -6 ..< -2, using: &generator)), exp(Float.random(in: -6 ..< -2, using: &generator)), exp(Float.random(in: -6 ..< -2, using: &generator)))
            let axis = simd_normalize(SIMD3<Float>(Float.random(in: -1...1, using: &generator), Float.random(in: -1...1, using: &generator), Float.random(in: -1...1, using: &generator)))
            let quaternion = simd_quatf(angle: Float.random(in: 0..<(2 * .pi), using: &generator), axis: axis)
            return SparkSplat(
                position: simd_half3(Float16(position.x), Float16(position.y), Float16(position.z)),
                scale: simd_half3(Float16(scale.x), Float16(scale.y), Float16(scale.z)),
                rotation: simd_half4(Float16(quaternion.imag.x), Float16(quaternion.imag.y), Float16(quaternion.imag.z), Float16(quaternion.real)),
                color: simd_uchar4(UInt8.random(in: 0...255, using: &generator), UInt8.random(in: 0...255, using: &generator), UInt8.random(in: 0...255, using: &generator), UInt8.random(in: 100...255, using: &generator))
            )
        }
    }

    @Test("pack/unpack round-trips within quantization error")
    func roundTrip() {
        let splats = Self.randomSplats(count: 1_000, seed: 42)
        let (elements, bounds) = PackedSplatCloud.pack(splats)
        #expect(MemoryLayout<GPSPackedSplat>.size == 18)

        let positionTolerance = simd_max(bounds.positionExtent / 65_535, SIMD3<Float>(repeating: 0.005))
        for (original, packed) in zip(splats, elements) {
            let decoded = PackedSplatCloud.unpack(packed, bounds: bounds)

            for axis in 0..<3 {
                let error = abs(Float(decoded.position[axis]) - Float(original.position[axis]))
                #expect(error <= positionTolerance[axis] + 0.005, "position axis \(axis): \(error)")
            }
            for axis in 0..<3 {
                let ratio = Float(decoded.scale[axis]) / Float(original.scale[axis])
                #expect(ratio > 0.98 && ratio < 1.02, "scale axis \(axis): \(ratio)")
            }
            let originalRotation = simd_normalize(SIMD4<Float>(Float(original.rotation.x), Float(original.rotation.y), Float(original.rotation.z), Float(original.rotation.w)))
            let decodedRotation = SIMD4<Float>(Float(decoded.rotation.x), Float(decoded.rotation.y), Float(decoded.rotation.z), Float(decoded.rotation.w))
            #expect(abs(simd_dot(originalRotation, decodedRotation)) > 0.999, "rotation dot: \(simd_dot(originalRotation, decodedRotation))")
            #expect(decoded.color == original.color)
        }
    }

    @Test("zero-scale splats pack with zero opacity")
    func zeroScale() {
        let splats = [
            SparkSplat(position: simd_half3(0, 0, 0), scale: simd_half3(0, 0, 0), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(255, 0, 0, 255)),
            SparkSplat(position: simd_half3(1, 0, 0), scale: simd_half3(repeating: 0.1), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(0, 255, 0, 200)),
        ]
        let (elements, _) = PackedSplatCloud.pack(splats)
        #expect(elements[0].color.3 == 0)
        #expect(elements[1].color.3 == 200)
    }

    @Test("packed rendering matches unpacked within quantization noise")
    func packedRenderingMatches() throws {
        let size = 128
        let splats = Self.randomSplats(count: 5_000, seed: 7)
        let cloud = try PackedSplatCloud(device: device, splats: splats)
        guard let buffer = device.makeBuffer(bytes: splats, length: MemoryLayout<SparkSplat>.stride * splats.count) else {
            throw TestError.bufferAllocationFailed
        }
        let camera = LookAt(position: SIMD3<Float>(0, 0, 6), target: .zero, up: SIMD3<Float>(0, 1, 0)).cameraMatrix
        let projection = PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01...100)).projectionMatrix(for: CGSize(width: size, height: size))

        // Accumulate both paths over the same seeds; the converged images
        // should agree apart from quantization error.
        let frames = 256
        var unpackedMean = [Float](repeating: 0, count: size * size * 4)
        var packedMean = [Float](repeating: 0, count: size * size * 4)
        let unpackedRenderer = try PointSplatRenderer(device: device, configuration: .init(width: size, height: size))
        let packedRenderer = try PointSplatRenderer(device: device, configuration: .init(width: size, height: size))
        for frame in 0..<frames {
            let unpackedTexture = try unpackedRenderer.render(splats: buffer, splatCount: splats.count, modelMatrix: .identity, viewMatrix: camera.inverse, projectionMatrix: projection, frameSeed: UInt32(frame))
            let packedTexture = try packedRenderer.render(packed: cloud, modelMatrix: .identity, viewMatrix: camera.inverse, projectionMatrix: projection, frameSeed: UInt32(frame))
            accumulate(&unpackedMean, texture: unpackedTexture, weight: 1 / Float(frames))
            accumulate(&packedMean, texture: packedTexture, weight: 1 / Float(frames))
        }

        var mse = 0.0
        for index in unpackedMean.indices {
            let difference = Double(unpackedMean[index] - packedMean[index])
            mse += difference * difference
        }
        mse /= Double(unpackedMean.count)
        let psnr = 10 * log10(1 / max(mse, 1e-12))
        #expect(psnr > 30, "packed vs unpacked PSNR: \(psnr) dB")
    }

    private func accumulate(_ accumulator: inout [Float], texture: MTLTexture, weight: Float) {
        var pixels = [Float](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { pointer in
            texture.getBytes(pointer.baseAddress!, bytesPerRow: texture.width * 16, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        for index in accumulator.indices {
            accumulator[index] += pixels[index] * weight
        }
    }
}
#endif

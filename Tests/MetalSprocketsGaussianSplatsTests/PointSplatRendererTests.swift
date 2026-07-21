#if !arch(x86_64)
import GeometryLite3D
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Testing

@Suite("PointSplatRenderer")
struct PointSplatRendererTests {
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

    private func makeSplatBuffer(_ splats: [SparkSplat]) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(bytes: splats, length: MemoryLayout<SparkSplat>.stride * splats.count) else {
            throw TestError.bufferAllocationFailed
        }
        return buffer
    }

    private func makeMatrices(size: Int) -> (view: simd_float4x4, projection: simd_float4x4) {
        let camera = LookAt(position: SIMD3<Float>(0, 0, 5), target: .zero, up: SIMD3<Float>(0, 1, 0)).cameraMatrix
        let projection = PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01...100))
        return (camera.inverse, projection.projectionMatrix(for: CGSize(width: size, height: size)))
    }

    private func readPixels(_ texture: MTLTexture) -> [SIMD4<Float>] {
        let count = texture.width * texture.height
        var pixels = [SIMD4<Float>](repeating: .zero, count: count)
        pixels.withUnsafeMutableBytes { pointer in
            texture.getBytes(pointer.baseAddress!, bytesPerRow: texture.width * MemoryLayout<SIMD4<Float>>.stride, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return pixels
    }

    @Test("accumulated frames converge on an opaque splat's color")
    func convergesOnSplatColor() throws {
        let size = 64
        let splat = SparkSplat(
            position: simd_half3(0, 0, 0),
            scale: simd_half3(repeating: 0.5),
            rotation: simd_half4(0, 0, 0, 1),
            color: simd_uchar4(255, 0, 0, 255)
        )
        let renderer = try PointSplatRenderer(device: device, configuration: .init(width: size, height: size, maxPointsPerFrame: 200_000))
        let buffer = try makeSplatBuffer([splat])
        let (view, projection) = makeMatrices(size: size)

        var accumulated = [SIMD4<Float>](repeating: .zero, count: size * size)
        let frames = 64
        for frame in 0..<frames {
            let texture = try renderer.render(splats: buffer, splatCount: 1, modelMatrix: .identity, viewMatrix: view, projectionMatrix: projection, frameSeed: UInt32(frame))
            for (i, pixel) in readPixels(texture).enumerated() {
                accumulated[i] += pixel
            }
        }
        let center = accumulated[(size / 2) * size + size / 2] / Float(frames)
        // Full-opacity red Gaussian at the mean: converged center pixel is red.
        #expect(center.x > 0.9, "center red channel: \(center.x)")
        #expect(center.y < 0.05)
        #expect(center.z < 0.05)

        // Far corner stays background (black).
        let corner = accumulated[0] / Float(frames)
        #expect(corner.x < 0.05, "corner should be background, got \(corner)")
    }

    @Test("fixed seed produces identical images")
    func deterministicWithFixedSeed() throws {
        let size = 32
        var splats = [SparkSplat]()
        for i in 0..<20 {
            let x = Float(i % 5) * 0.4 - 0.8
            let y = Float(i / 5) * 0.4 - 0.6
            let position = simd_half3(Float16(x), Float16(y), Float16(0))
            let color = simd_uchar4(UInt8(50 + i * 10), 100, 200, 200)
            splats.append(SparkSplat(position: position, scale: simd_half3(repeating: 0.2), rotation: simd_half4(0, 0, 0, 1), color: color))
        }
        let renderer = try PointSplatRenderer(device: device, configuration: .init(width: size, height: size, maxPointsPerFrame: 200_000))
        let buffer = try makeSplatBuffer(splats)
        let (view, projection) = makeMatrices(size: size)

        let first = try renderer.render(splats: buffer, splatCount: splats.count, modelMatrix: .identity, viewMatrix: view, projectionMatrix: projection, frameSeed: 42)
        let firstPixels = readPixels(first)
        let second = try renderer.render(splats: buffer, splatCount: splats.count, modelMatrix: .identity, viewMatrix: view, projectionMatrix: projection, frameSeed: 42)
        let secondPixels = readPixels(second)
        #expect(firstPixels == secondPixels)
    }

    @Test("empty scene renders background")
    func emptyScene() throws {
        let size = 16
        let background = SIMD3<Float>(0.25, 0.5, 0.75)
        let renderer = try PointSplatRenderer(device: device, configuration: .init(width: size, height: size, maxPointsPerFrame: 200_000, backgroundColor: background))
        let splat = SparkSplat(position: simd_half3(0, 0, 0), scale: simd_half3(repeating: 0.1), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(255, 255, 255, 0))
        let buffer = try makeSplatBuffer([splat])
        let (view, projection) = makeMatrices(size: size)

        let texture = try renderer.render(splats: buffer, splatCount: 1, modelMatrix: .identity, viewMatrix: view, projectionMatrix: projection, frameSeed: 1)
        for pixel in readPixels(texture) {
            #expect(abs(pixel.x - background.x) < 0.01)
            #expect(abs(pixel.y - background.y) < 0.01)
            #expect(abs(pixel.z - background.z) < 0.01)
        }
    }

    @Test("closer splat wins depth resolution")
    func depthOrdering() throws {
        let size = 64
        // Two overlapping opaque splats; green is closer to the camera.
        let red = SparkSplat(position: simd_half3(0, 0, -1), scale: simd_half3(repeating: 0.5), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(255, 0, 0, 255))
        let green = SparkSplat(position: simd_half3(0, 0, 1), scale: simd_half3(repeating: 0.5), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(0, 255, 0, 255))
        let renderer = try PointSplatRenderer(device: device, configuration: .init(width: size, height: size, maxPointsPerFrame: 200_000))
        let buffer = try makeSplatBuffer([red, green])
        let (view, projection) = makeMatrices(size: size)

        var accumulated = SIMD4<Float>.zero
        let frames = 32
        for frame in 0..<frames {
            let texture = try renderer.render(splats: buffer, splatCount: 2, modelMatrix: .identity, viewMatrix: view, projectionMatrix: projection, frameSeed: UInt32(frame))
            accumulated += readPixels(texture)[(size / 2) * size + size / 2]
        }
        let center = accumulated / Float(frames)
        #expect(center.y > 0.9, "center should be green (closer splat), got \(center)")
        #expect(center.x < 0.05)
    }
}
#endif

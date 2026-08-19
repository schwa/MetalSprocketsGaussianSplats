#if !arch(x86_64)
import GeometryLite3D
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Testing

@Suite("PointSplatComputePass", .enabled(if: MetalTestSupport.supports64BitAtomics))
struct PointSplatComputePassTests {
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
        let renderer = try PointSplatTestRenderer(device: device, width: size, height: size)
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
        // A full-opacity red Gaussian at the mean. The converged center pixel is red.
        #expect(center.x > 0.9, "center red channel: \(center.x)")
        #expect(center.y < 0.05)
        #expect(center.z < 0.05)

        // The far corner stays background (black).
        let corner = accumulated[0] / Float(frames)
        #expect(corner.x < 0.05, "corner should be background, got \(corner)")
    }

    @Test("2x2 supersampling with K=4 converges on splat color")
    func supersampledConvergence() throws {
        let size = 64
        let splat = SparkSplat(
            position: simd_half3(0, 0, 0),
            scale: simd_half3(repeating: 0.5),
            rotation: simd_half4(0, 0, 0, 1),
            color: simd_uchar4(255, 0, 0, 255)
        )
        let renderer = try PointSplatTestRenderer(device: device, width: size, height: size, supersampling: 2, pointsPerThread: 4)
        let buffer = try makeSplatBuffer([splat])
        let (view, projection) = makeMatrices(size: size)

        var accumulated = [SIMD4<Float>](repeating: .zero, count: size * size)
        let frames = 64
        for frame in 0..<frames {
            let texture = try renderer.render(splats: buffer, splatCount: 1, modelMatrix: .identity, viewMatrix: view, projectionMatrix: projection, frameSeed: UInt32(frame))
            #expect(texture.width == size && texture.height == size)
            for (i, pixel) in readPixels(texture).enumerated() {
                accumulated[i] += pixel
            }
        }
        let center = accumulated[(size / 2) * size + size / 2] / Float(frames)
        #expect(center.x > 0.9, "center red channel: \(center.x)")
        #expect(center.y < 0.05)
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
        let renderer = try PointSplatTestRenderer(device: device, width: size, height: size)
        let buffer = try makeSplatBuffer(splats)
        let (view, projection) = makeMatrices(size: size)

        let first = try renderer.render(splats: buffer, splatCount: splats.count, modelMatrix: .identity, viewMatrix: view, projectionMatrix: projection, frameSeed: 42)
        let firstPixels = readPixels(first)
        let second = try renderer.render(splats: buffer, splatCount: splats.count, modelMatrix: .identity, viewMatrix: view, projectionMatrix: projection, frameSeed: 42)
        let secondPixels = readPixels(second)
        #expect(firstPixels == secondPixels)
    }

    @Test("group culling keeps visible splats across many culled groups")
    func groupCullingPreservesVisibleSplats() throws {
        // Regression for #75. There are more than 4 groups of 256 splats. Every
        // group but one is behind the camera or far outside the frustum. The
        // group-level cull must drop those wholesale and keep the one visible
        // red splat.
        let size = 64
        var splats = [SparkSplat]()
        for i in 0..<1_200 {
            // Behind the camera (the camera is at z=5 and looks at the origin).
            let offset = Float(i % 7)
            splats.append(SparkSplat(position: simd_half3(Float16(offset), Float16(offset), 50), scale: simd_half3(repeating: 0.2), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(0, 255, 0, 255)))
        }
        // Far outside the frustum, in front of the camera.
        for i in 0..<300 {
            splats.append(SparkSplat(position: simd_half3(Float16(200 + Float(i % 5)), 0, 0), scale: simd_half3(repeating: 0.2), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(0, 0, 255, 255)))
        }
        // A single visible splat, in the last partial group.
        splats.append(SparkSplat(position: simd_half3(0, 0, 0), scale: simd_half3(repeating: 0.5), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(255, 0, 0, 255)))

        let renderer = try PointSplatTestRenderer(device: device, width: size, height: size)
        let buffer = try makeSplatBuffer(splats)
        let (view, projection) = makeMatrices(size: size)

        var accumulated = [SIMD4<Float>](repeating: .zero, count: size * size)
        let frames = 64
        for frame in 0..<frames {
            let texture = try renderer.render(splats: buffer, splatCount: splats.count, modelMatrix: .identity, viewMatrix: view, projectionMatrix: projection, frameSeed: UInt32(frame))
            for (i, pixel) in readPixels(texture).enumerated() {
                accumulated[i] += pixel
            }
        }
        let center = accumulated[(size / 2) * size + size / 2] / Float(frames)
        #expect(center.x > 0.9, "center red channel: \(center.x)")
        #expect(center.y < 0.05, "culled green splats leaked: \(center.y)")
        #expect(center.z < 0.05, "culled blue splats leaked: \(center.z)")
    }

    @Test("empty scene renders background")
    func emptyScene() throws {
        let size = 16
        let background = SIMD3<Float>(0.25, 0.5, 0.75)
        let renderer = try PointSplatTestRenderer(device: device, width: size, height: size, backgroundColor: background)
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
        // Two overlapping opaque splats. Green is closer to the camera.
        let red = SparkSplat(position: simd_half3(0, 0, -1), scale: simd_half3(repeating: 0.5), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(255, 0, 0, 255))
        let green = SparkSplat(position: simd_half3(0, 0, 1), scale: simd_half3(repeating: 0.5), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(0, 255, 0, 255))
        let renderer = try PointSplatTestRenderer(device: device, width: size, height: size)
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

    @Test("sub-pixel splat renders partial coverage without vanishing")
    func subPixelSplatPartialCoverage() throws {
        let size = 64
        // At scale 0.009 and z = 5 with a 64-px target, the projected sigma is
        // ~0.1 px. 3-sigma stays well under half a pixel. The exact path (RFC
        // 0005 §5) integrates the mass ~2*pi*sigma^2 ~= 0.06. Full opacity red.
        let splat = SparkSplat(
            position: simd_half3(0, 0, 0),
            scale: simd_half3(repeating: 0.009),
            rotation: simd_half4(0, 0, 0, 1),
            color: simd_uchar4(255, 0, 0, 255)
        )
        let renderer = try PointSplatTestRenderer(device: device, width: size, height: size)
        let buffer = try makeSplatBuffer([splat])
        let (view, projection) = makeMatrices(size: size)

        var totalRed: Float = 0
        let frames = 256
        for frame in 0..<frames {
            let texture = try renderer.render(splats: buffer, splatCount: 1, modelMatrix: .identity, viewMatrix: view, projectionMatrix: projection, frameSeed: UInt32(frame))
            // Sum over a neighborhood. The mean subpixel can straddle a pixel boundary.
            for y in (size / 2 - 2)...(size / 2 + 2) {
                for x in (size / 2 - 2)...(size / 2 + 2) {
                    totalRed += readPixels(texture)[y * size + x].x
                }
            }
        }
        let meanCoverage = totalRed / Float(frames)
        // The integrated opacity mass of a truly sub-pixel Gaussian is a proper
        // fraction. It must not vanish and must not saturate. Before #108, the
        // floor-dilation path washed it out at low alpha.
        #expect(meanCoverage > 0.01, "sub-pixel splat vanished: \(meanCoverage)")
        #expect(meanCoverage < 1.0, "sub-pixel splat saturated: \(meanCoverage)")
    }

    @Test("nextAccumulationStep is idempotent per frame index")
    func accumulationStepIdempotent() throws {
        let resources = try PointSplatResources(device: device, drawableSize: SIMD2<Float>(8, 8), splatCount: 1, supersampling: 1, pointsPerThread: 1)
        let first = resources.nextAccumulationStep(frameIndex: 0, cameraMatrix: .identity, modelMatrix: .identity, projectionMatrix: .identity)
        #expect(resources.accumulatedFrames == 1)
        // A second call for the same frame must not advance the parity or the count.
        let repeated = resources.nextAccumulationStep(frameIndex: 0, cameraMatrix: .identity, modelMatrix: .identity, projectionMatrix: .identity)
        #expect(resources.accumulatedFrames == 1)
        #expect(repeated.input === first.input)
        #expect(repeated.output === first.output)
        #expect(repeated.blendFactor == first.blendFactor)
        // A new frame advances. The ping-pong swaps and the mean weight drops.
        let next = resources.nextAccumulationStep(frameIndex: 1, cameraMatrix: .identity, modelMatrix: .identity, projectionMatrix: .identity)
        #expect(resources.accumulatedFrames == 2)
        #expect(next.input === first.output)
        #expect(next.blendFactor == 0.5)
    }
}
#endif

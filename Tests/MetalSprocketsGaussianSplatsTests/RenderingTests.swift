#if !arch(x86_64)
import CoreGraphics
import Foundation
import GoldenImage
import Metal
import MetalSprockets
@testable import MetalSprocketsGaussianSplats
import simd
@testable import Splats
import Testing

@Suite
struct TypedMTLBufferTests {
    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noMetalDevice
        }
        self.device = device
    }

    @Test
    func testCreateEmptyBuffer() throws {
        let buffer: TypedMTLBuffer<Float> = try device.makeTypedBuffer(element: Float.self, capacity: 100, options: [])
        #expect(buffer.isEmpty)
        #expect(buffer.capacity == 100)
    }

    @Test
    func testCreateBufferWithValues() throws {
        let values: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        let buffer: TypedMTLBuffer<Float> = try device.makeTypedBuffer(values: values, options: [])
        #expect(buffer.count == 5)
        #expect(buffer.capacity >= 5)
    }

    @Test
    func testBufferSubscript() throws {
        let values: [Float] = [1.0, 2.0, 3.0]
        var buffer: TypedMTLBuffer<Float> = try device.makeTypedBuffer(values: values, options: [])

        #expect(buffer[0] == 1.0)
        #expect(buffer[1] == 2.0)
        #expect(buffer[2] == 3.0)

        buffer[1] = 42.0
        #expect(buffer[1] == 42.0)
    }

    @Test
    func testBufferIteration() throws {
        let values: [Float] = [1.0, 2.0, 3.0, 4.0]
        let buffer: TypedMTLBuffer<Float> = try device.makeTypedBuffer(values: values, options: [])

        let collected = Array(buffer)
        #expect(collected == values)
    }

    @Test
    func testBufferEquality() throws {
        let values: [Float] = [1.0, 2.0, 3.0]
        let buffer1: TypedMTLBuffer<Float> = try device.makeTypedBuffer(values: values, options: [])
        let buffer2: TypedMTLBuffer<Float> = try device.makeTypedBuffer(values: values, options: [])
        let buffer3: TypedMTLBuffer<Float> = try device.makeTypedBuffer(values: [1.0, 2.0, 4.0], options: [])

        #expect(buffer1 == buffer2)
        #expect(buffer1 != buffer3)
    }

    @Test
    func testBufferWithUnsafePointer() throws {
        let values: [Int32] = [10, 20, 30]
        let buffer: TypedMTLBuffer<Int32> = try device.makeTypedBuffer(values: values, options: [])

        let sum = buffer.withUnsafeBufferPointer { ptr in
            ptr.reduce(0, +)
        }
        #expect(sum == 60)
    }

    @Test
    func testBufferLabel() throws {
        let buffer: TypedMTLBuffer<Float> = try device.makeTypedBuffer(values: [1.0], options: [])
            .labeled("TestBuffer")
        #expect(buffer.unsafeMTLBuffer.label == "TestBuffer")
    }
}

@Suite
struct GenericSplatConversionTests {
    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noMetalDevice
        }
        self.device = device
    }

    @Test
    func testGenericSplatToAntimatter15GPUSplat() throws {
        let genericSplat = GenericSplat(
            position: [1, 2, 3],
            scale: [0.1, 0.2, 0.3],
            color: [1, 0, 0, 1],
            rotation: .init(ix: 0, iy: 0, iz: 0, r: 1)
        )

        let gpuSplat = Antimatter15GPUSplat(genericSplat)
        #expect(gpuSplat.position.x == 1)
        #expect(gpuSplat.position.y == 2)
        #expect(gpuSplat.position.z == 3)
        #expect(gpuSplat.color.x == 255)  // Red channel
        #expect(gpuSplat.color.w == 255)  // Alpha channel
    }

    @Test
    func testGenericSplatToSparkSplat() throws {
        let genericSplat = GenericSplat(
            position: [4, 5, 6],
            scale: [0.5, 0.5, 0.5],
            color: [0, 1, 0, 0.5],
            rotation: .init(ix: 0, iy: 0, iz: 0, r: 1)
        )

        let gpuSplat = SparkSplat(genericSplat)
        #expect(gpuSplat.position.x == 4)
        #expect(gpuSplat.position.y == 5)
        #expect(gpuSplat.position.z == 6)
        #expect(gpuSplat.color.y == 255)  // Green channel
        #expect(gpuSplat.color.w == 127 || gpuSplat.color.w == 128)  // Alpha ~ 0.5
    }
}

@Suite
struct GPUSplatCloudTests {
    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noMetalDevice
        }
        self.device = device
    }

    @Test
    func testGPUSplatCloudCreation() throws {
        let splats = [
            Antimatter15GPUSplat.testSplat(position: [0, 0, 0]),
            Antimatter15GPUSplat.testSplat(position: [1, 0, 0])
        ]

        let splatBuffer = try device.makeTypedBuffer(values: splats, options: [])
        let cloud = try GPUSplatCloud<Antimatter15GPUSplat>(
            device: device,
            splats: splatBuffer,
            cameraMatrix: .identity,
            modelMatrix: .identity
        )

        #expect(cloud.count == 2)
    }

    @Test
    func testGPUSplatCloudWithManySplats() throws {
        // Test with a larger number of splats
        let splats = (0..<100).map { i in
            Antimatter15GPUSplat.testSplat(position: [Float(i), 0, 0])
        }

        let splatBuffer = try device.makeTypedBuffer(values: splats, options: [])
        let cloud = try GPUSplatCloud<Antimatter15GPUSplat>(
            device: device,
            splats: splatBuffer,
            cameraMatrix: .identity,
            modelMatrix: .identity
        )

        #expect(cloud.count == 100)
    }
}

// MARK: - Test Helpers

enum TestError: Error {
    case noMetalDevice
}

extension Antimatter15GPUSplat {
    static func testSplat(position: SIMD3<Float>) -> Antimatter15GPUSplat {
        Antimatter15GPUSplat(
            position: position,
            u1: simd_half2(1, 0),
            u2: simd_half2(0, 1),
            u3: simd_half2(0, 0),
            color: SIMD4<UInt8>(255, 0, 0, 255)
        )
    }
}

extension simd_float4x4 {
    static var identity: simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}

// MARK: - Actual Rendering Tests

@Suite
struct SplatRenderingTests {
    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noMetalDevice
        }
        self.device = device
    }

    @Test
    @MainActor
    func testAntimatter15Rendering() throws {
        // Create test splats - a simple red splat at origin
        let splats = [
            Antimatter15GPUSplat.testSplat(position: [0, 0, -5])
        ]

        let splatBuffer = try device.makeTypedBuffer(values: splats, options: [])

        // Set up camera looking at the splat
        let cameraMatrix = simd_float4x4.identity
        let modelMatrix = simd_float4x4.identity

        let cloud = try GPUSplatCloud<Antimatter15GPUSplat>(
            device: device,
            splats: splatBuffer,
            cameraMatrix: cameraMatrix,
            modelMatrix: modelMatrix
        )

        // Create projection matrix
        let size = CGSize(width: 512, height: 512)
        let aspect = Float(size.width / size.height)
        let projectionMatrix = perspectiveProjection(fovY: .pi / 4, aspect: aspect, near: 0.1, far: 100)

        // Create the render pipeline
        let renderPipeline = try Antimatter15SplatRenderPipeline(
            splatCloud: cloud,
            projectionMatrix: projectionMatrix,
            modelMatrix: modelMatrix,
            cameraMatrix: cameraMatrix,
            drawableSize: SIMD2<Float>(Float(size.width), Float(size.height)),
            debugMode: .filled
        )

        // Render offscreen
        let offscreenRenderer = try OffscreenRenderer(size: size)
        let renderPass = try RenderPass {
            renderPipeline
        }
        let rendering = try offscreenRenderer.render(renderPass)

        // Basic validation - check we got a texture
        #expect(rendering.texture.width == Int(size.width))
        #expect(rendering.texture.height == Int(size.height))

        // Compare with golden image
        let image = try rendering.cgImage
        let goldenImagesDir = try #require(Bundle.module.resourceURL?.appendingPathComponent("Golden Images"))
        let comparison = GoldenImageComparison(imageDirectory: goldenImagesDir, options: .none)
        let isMatch = try comparison.image(image: image, matchesGoldenImageNamed: "Antimatter15SingleSplat")
        #expect(isMatch)
    }
}

// MARK: - Math Helpers

private func perspectiveProjection(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let yScale = 1 / tan(fovY * 0.5)
    let xScale = yScale / aspect
    let zRange = far - near
    let zScale = -(far + near) / zRange
    let wzScale = -2 * far * near / zRange

    return simd_float4x4(
        SIMD4<Float>(xScale, 0, 0, 0),
        SIMD4<Float>(0, yScale, 0, 0),
        SIMD4<Float>(0, 0, zScale, -1),
        SIMD4<Float>(0, 0, wzScale, 0)
    )
}

#endif

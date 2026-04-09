#if !arch(x86_64)
import CoreGraphics
import Foundation
import Metal
import MetalSprockets
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
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
        let genericSplats = [
            GenericSplat(position: [0, 0, 0], scale: [0.1, 0.1, 0.1], color: [1, 0, 0, 1], rotation: .init(ix: 0, iy: 0, iz: 0, r: 1)),
            GenericSplat(position: [1, 0, 0], scale: [0.1, 0.1, 0.1], color: [0, 1, 0, 1], rotation: .init(ix: 0, iy: 0, iz: 0, r: 1))
        ]
        let splats = genericSplats.map { SparkSplat($0) }
        let splatBuffer = try device.makeTypedBuffer(values: splats, options: [])
        let cloud = GPUSplatCloud<SparkSplat>(splats: splatBuffer)
        #expect(cloud.count == 2)
    }

    @Test
    func testGPUSplatCloudWithManySplats() throws {
        let splats = (0..<100).map { i in
            SparkSplat(GenericSplat(position: [Float(i), 0, 0], scale: [0.1, 0.1, 0.1], color: [1, 0, 0, 1], rotation: .init(ix: 0, iy: 0, iz: 0, r: 1)))
        }
        let splatBuffer = try device.makeTypedBuffer(values: splats, options: [])
        let cloud = GPUSplatCloud<SparkSplat>(splats: splatBuffer)
        #expect(cloud.count == 100)
    }
}

enum TestError: Error {
    case noMetalDevice
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

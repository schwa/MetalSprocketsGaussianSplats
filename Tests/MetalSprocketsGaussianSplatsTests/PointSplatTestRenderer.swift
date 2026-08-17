#if !arch(x86_64)
import Metal
import MetalSprockets
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd

/// Test-local blocking wrapper: runs ``PointSplatComputePass`` into a
/// CPU-readable float texture, one stochastic frame per call.
final class PointSplatTestRenderer {
    enum Error: Swift.Error {
        case textureAllocationFailed
    }

    private let runner: Runner
    private let texture: MTLTexture
    private let backgroundColor: SIMD3<Float>
    private let supersampling: Int
    private let pointsPerThread: Int
    /// Monotonic plan key; frame seeds can repeat.
    private var planCounter: UInt64 = 0

    init(device: MTLDevice, width: Int, height: Int, supersampling: Int = 1, pointsPerThread: Int = 1, backgroundColor: SIMD3<Float> = .zero) throws {
        runner = try Runner(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Error.textureAllocationFailed
        }
        texture.label = "PointSplat resolve"
        self.texture = texture
        self.backgroundColor = backgroundColor
        self.supersampling = supersampling
        self.pointsPerThread = pointsPerThread
    }

    func render(splats: MTLBuffer, splatCount: Int, packedBounds: GPSPackedSplatBounds? = nil, modelMatrix: simd_float4x4, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, frameSeed: UInt32) throws -> MTLTexture {
        planCounter += 1
        let pass = PointSplatComputePass(
            splats: splats,
            splatCount: splatCount,
            packedBounds: packedBounds,
            modelMatrix: modelMatrix,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            frameSeed: frameSeed,
            planKey: planCounter,
            outTexture: texture,
            backgroundColor: backgroundColor,
            supersampling: supersampling,
            pointsPerThread: pointsPerThread
        )
        try runner.run(pass)
        return texture
    }

    func render(packed cloud: PackedSplatCloud, modelMatrix: simd_float4x4, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, frameSeed: UInt32) throws -> MTLTexture {
        try render(splats: cloud.buffer, splatCount: cloud.count, packedBounds: cloud.bounds, modelMatrix: modelMatrix, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, frameSeed: frameSeed)
    }
}
#endif

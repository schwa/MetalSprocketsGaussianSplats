#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

public struct Antimatter15TileCountComputePass: Element {
    var splatCloud: SplatCloud<Antimatter15GPUSplat>
    var projectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var cameraMatrix: simd_float4x4
    var drawableSize: SIMD2<Float>
    var tileSize: UInt32
    var tileBuffer: TypedMTLBuffer<UInt32>
    var maxCountBuffer: TypedMTLBuffer<UInt32>

    @MSState
    var computeKernel: ComputeKernel

    public init(
        splatCloud: SplatCloud<Antimatter15GPUSplat>,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        drawableSize: SIMD2<Float>,
        tileSize: UInt32 = 16,
        tileBuffer: TypedMTLBuffer<UInt32>,
        maxCountBuffer: TypedMTLBuffer<UInt32>
    ) throws {
        self.splatCloud = splatCloud
        var projectionMatrix = projectionMatrix
        projectionMatrix[1][1] *= -1
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
        self.tileSize = tileSize
        self.tileBuffer = tileBuffer
        self.maxCountBuffer = maxCountBuffer

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders()).namespaced("Antimatter15SplatTileCoverage")
        self.computeKernel = try shaderLibrary.function(named: "compute_tile_overlaps", type: ComputeKernel.self)
    }

    public var body: some Element {
        get throws {
            try BlitPass {
                Blit { encoder in
                    encoder.fill(buffer: tileBuffer.unsafeMTLBuffer, range: 0..<tileBuffer.unsafeMTLBuffer.length, value: 0)
                    encoder.fill(buffer: maxCountBuffer.unsafeMTLBuffer, range: 0..<maxCountBuffer.unsafeMTLBuffer.length, value: 0)
                }
            }

            try ComputePass(label: "Tile Count Compute") {
                try ComputePipeline(computeKernel: computeKernel) {
                    try ComputeDispatch(
                        threadsPerGrid: MTLSize(width: splatCloud.count, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
                    )
                    .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
                    .parameter("splatCount", value: UInt32(splatCloud.count))
                    .parameter("modelMatrix", value: modelMatrix)
                    .parameter("viewMatrix", value: cameraMatrix.inverse)
                    .parameter("projectionMatrix", value: projectionMatrix)
                    .parameter("drawableSize", value: drawableSize)
                    .parameter("scale", value: Float(2.0))
                    .parameter("tileGridSize", value: tileGridSize)
                    .parameter("tileCounts", buffer: tileBuffer.unsafeMTLBuffer)
                    .parameter("maxCount", buffer: maxCountBuffer.unsafeMTLBuffer)
                }
            }
        }
    }

    private var tileGridSize: SIMD2<UInt32> {
        let width = UInt32(ceil(drawableSize.x / Float(tileSize)))
        let height = UInt32(ceil(drawableSize.y / Float(tileSize)))
        return SIMD2(width, height)
    }
}
#endif

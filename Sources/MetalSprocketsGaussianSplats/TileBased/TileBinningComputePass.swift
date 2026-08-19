#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders

/// Compute pass that counts splats per tile (phase 1 of two-phase binning).
///
/// - Important: This type is part of the **experimental** tile-based renderer.
///   It can change or move in a future version.
struct TileBinningCountPass: Element {
    // MARK: - Properties

    var splatCloud: GPUSplatCloud<SparkSplat>
    var projectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var cameraMatrix: simd_float4x4
    var drawableSize: SIMD2<Float>
    var tileSplatResources: TileSplatResources

    @MSState
    var computeKernel: ComputeKernel

    // MARK: - Initialization

    init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        drawableSize: SIMD2<Float>,
        tileSplatResources: TileSplatResources
    ) throws {
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
        self.tileSplatResources = tileSplatResources

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
            .namespaced("TileSplatBinning")
        self.computeKernel = try shaderLibrary.function(named: "tile_binning_count", type: ComputeKernel.self)
    }

    // MARK: - Element Body

    var body: some Element {
        get throws {
            // Clear the tile counters before the count.
            try BlitPass {
                Blit { encoder in
                    encoder.fill(
                        buffer: tileSplatResources.tileCounters.unsafeMTLBuffer,
                        range: 0..<tileSplatResources.tileCounters.unsafeMTLBuffer.length,
                        value: 0
                    )
                }
            }

            // Run the count kernel with one thread per splat.
            try ComputePass(label: "Tile Binning Count") {
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
                    .parameter("tileGridSize", value: tileSplatResources.tileGridSize)
                    .parameter("tileCounters", buffer: tileSplatResources.tileCounters.unsafeMTLBuffer)
                }
            }
        }
    }
}

/// Compute pass that writes splats to the compacted buffer (phase 2 of two-phase binning).
///
/// - Important: This type is part of the **experimental** tile-based renderer.
///   It can change or move in a future version.
struct TileBinningWritePass: Element {
    // MARK: - Properties

    var splatCloud: GPUSplatCloud<SparkSplat>
    var projectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var cameraMatrix: simd_float4x4
    var drawableSize: SIMD2<Float>
    var tileSplatResources: TileSplatResources

    @MSState
    var computeKernel: ComputeKernel

    // MARK: - Initialization

    init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        drawableSize: SIMD2<Float>,
        tileSplatResources: TileSplatResources
    ) throws {
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
        self.tileSplatResources = tileSplatResources

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
            .namespaced("TileSplatBinning")
        self.computeKernel = try shaderLibrary.function(named: "tile_binning_write", type: ComputeKernel.self)
        try tileSplatResources.ensureProjectedSplatCapacity(splatCloud.count)
    }

    // MARK: - Element Body

    var body: some Element {
        get throws {
            // Clear the tile counters before the write. The write reuses them as local indices.
            try BlitPass {
                Blit { encoder in
                    encoder.fill(
                        buffer: tileSplatResources.tileCounters.unsafeMTLBuffer,
                        range: 0..<tileSplatResources.tileCounters.unsafeMTLBuffer.length,
                        value: 0
                    )
                }
            }

            // Run the write kernel with one thread per splat.
            try ComputePass(label: "Tile Binning Write") {
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
                    .parameter("tileGridSize", value: tileSplatResources.tileGridSize)
                    .parameter("tileCounters", buffer: tileSplatResources.tileCounters.unsafeMTLBuffer)
                    .parameter("tileSplatIndices", buffer: tileSplatResources.tileSplatIndicesA.unsafeMTLBuffer)
                    .parameter("tileOffsets", buffer: tileSplatResources.tileOffsets.unsafeMTLBuffer)
                    .parameter("maxTotalIntersections", value: UInt32(TileSplatResources.maxTotalSplatTileIntersections))
                    .parameter("projectedSplats", buffer: tileSplatResources.projectedSplats.unsafeMTLBuffer)
                }
            }
        }
    }
}

#endif

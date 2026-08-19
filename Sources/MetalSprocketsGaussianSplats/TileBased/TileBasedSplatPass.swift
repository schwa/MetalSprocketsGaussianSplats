#if !arch(x86_64)
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI
import MetalSupport
internal import os
import SwiftUI

/// A tile-based splat rendering pass that bins, sorts, and renders splats per tile.
///
/// - Important: This renderer is **experimental**. It can change or move in a
///   future version. Use ``SparkSplatRenderPipeline`` for production.
public struct TileBasedSplatPass: Element {
    private var splatCloud: GPUSplatCloud<SparkSplat>
    private var projection: any ProjectionProtocol
    private var cameraMatrix: simd_float4x4
    private var modelMatrix: simd_float4x4
    private var debugTileBorders: Bool
    private var showHeatMap: Bool
    var onFrameCompleted: (@Sendable (TileSplatResources) -> Void)?
    private var drawableSize: SIMD2<Float>

    @MSState private var resources: TileSplatResources

    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projection: any ProjectionProtocol,
        drawableSize: SIMD2<Float>,
        cameraMatrix: simd_float4x4,
        modelMatrix: simd_float4x4 = .identity,
        debugTileBorders: Bool = false,
        showHeatMap: Bool = false
    ) throws {
        self.splatCloud = splatCloud
        self.projection = projection
        self.drawableSize = drawableSize
        self.cameraMatrix = cameraMatrix
        self.modelMatrix = modelMatrix
        self.debugTileBorders = debugTileBorders
        self.showHeatMap = showHeatMap
        self.resources = try Self.makeResources(drawableSize: drawableSize)
    }

    public var body: some Element {
        get throws {
            let projectionMatrix = projection.projectionMatrix(aspectRatio: drawableSize.x / drawableSize.y)

            // Pass 1a: count the splats per tile.
            try TileBinningCountPass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: drawableSize,
                tileSplatResources: resources
            )
            .onChange(of: drawableSize) { _, _ in
                resources = try! Self.makeResources(drawableSize: drawableSize)
            }

            // Pass 1b: compute the prefix sum of the tile counts.
            try TilePrefixSumComputePass(
                tileSplatResources: resources
            )

            // Pass 1c: write the splats to the compacted buffer with the offsets.
            try TileBinningWritePass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: drawableSize,
                tileSplatResources: resources
            )

            // Pass 2: sort the splats within each tile by depth.
            try TileSortingComputePass(
                tileSplatResources: resources
            )

            // Pass 3: render the splats with an imageblock fragment shader.
            try RenderPass {
                try TileSplatRenderPass(
                    splatCloud: splatCloud,
                    tileSplatResources: resources,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    debugTileBorders: debugTileBorders
                )
            }
            .renderPassDescriptorModifier { descriptor in
                descriptor.tileWidth = Int(TILE_SIZE)
                descriptor.tileHeight = Int(TILE_SIZE)
                // half4 = 8 bytes, aligned to 16 bytes.
                descriptor.imageblockSampleLength = 16
            }

            // Optional heatmap overlay that shows the splat density per tile.
            if showHeatMap {
                try RenderPass {
                    try TileHeatMapRenderPass(tileSplatResources: resources, showTileBorders: debugTileBorders)
                }
            }

            // Copy the tile counters to the readback buffer for stats.
            try BlitPass {
                Blit { encoder in
                    encoder.copy(
                        from: resources.tileCounters.unsafeMTLBuffer,
                        sourceOffset: 0,
                        to: resources.tileCountersReadback.unsafeMTLBuffer,
                        destinationOffset: 0,
                        size: resources.tileCounters.unsafeMTLBuffer.length
                    )
                }
            }
            .onCommandBufferCompleted { _ in
                onFrameCompleted?(resources)
            }
        }
    }

    static func makeResources(drawableSize: SIMD2<Float>) throws -> TileSplatResources {
        let device = _MTLCreateSystemDefaultDevice()
        return try TileSplatResources(device: device, drawableSize: drawableSize)
    }
}

#endif

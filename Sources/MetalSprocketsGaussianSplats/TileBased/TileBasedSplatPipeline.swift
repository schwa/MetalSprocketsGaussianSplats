#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders

/// Complete tile-based splat rendering pipeline that combines binning, sorting, and rendering passes.
///
/// - Important: This renderer is **experimental**. It can change or move in a
///   future version. Use ``SparkSplatRenderPipeline`` for production.
///
/// This is an Element-based pipeline for RenderPass contexts. For SwiftUI, use
/// TileBasedSplatView instead.
public struct TileBasedSplatPipeline: Element {
    // MARK: - Properties

    var splatCloud: GPUSplatCloud<SparkSplat>
    var projectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var cameraMatrix: simd_float4x4
    var drawableSize: SIMD2<Float>
    var tileSplatResources: TileSplatResources
    var debugTileBorders: Bool
    var showHeatMap: Bool

    // MARK: - Initialization

    init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        drawableSize: SIMD2<Float>,
        tileSplatResources: TileSplatResources,
        debugTileBorders: Bool = false,
        showHeatMap: Bool = false
    ) {
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
        self.tileSplatResources = tileSplatResources
        self.debugTileBorders = debugTileBorders
        self.showHeatMap = showHeatMap
    }

    // MARK: - Element Body

    public var body: some Element {
        get throws {
            // Pass 1a: count the splats per tile.
            try TileBinningCountPass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: drawableSize,
                tileSplatResources: tileSplatResources
            )

            // Pass 1b: compute the prefix sum of the tile counts.
            try TilePrefixSumComputePass(
                tileSplatResources: tileSplatResources
            )

            // Pass 1c: write the splats to the compacted buffer with the offsets.
            try TileBinningWritePass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: drawableSize,
                tileSplatResources: tileSplatResources
            )

            // Pass 2: sort each tile's splat list by depth (front-to-back).
            try TileSortingComputePass(
                tileSplatResources: tileSplatResources
            )

            // Pass 3: render each pixel from the sorted splat lists, with early
            // alpha termination.
            try RenderPass {
                try TileSplatRenderPass(
                    splatCloud: splatCloud,
                    tileSplatResources: tileSplatResources,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    debugTileBorders: debugTileBorders
                )
            }
            .renderPassDescriptorModifier { descriptor in
                descriptor.tileWidth = Int(TILE_SIZE)
                descriptor.tileHeight = Int(TILE_SIZE)
                // TileSplatImageblock holds half4 = 4 * 2 bytes = 8 bytes, aligned to 16.
                descriptor.imageblockSampleLength = 16
            }

            // Optional heatmap overlay that shows the splat density per tile.
            if showHeatMap {
                try RenderPass {
                    try TileHeatMapRenderPass(tileSplatResources: tileSplatResources)
                }
            }
        }
    }
}

#endif

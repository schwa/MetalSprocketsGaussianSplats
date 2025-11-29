#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI
internal import os
import SwiftUI

public struct TileBasedSplatView: View {
    private var splatCloud: SplatCloud<SparkSplat>
    private var projection: any ProjectionProtocol
    private var cameraMatrix: simd_float4x4
    private var modelMatrix: simd_float4x4
    private var debugTileBorders: Bool
    private var showHeatMap: Bool
    private var onResourcesChanged: ((TileSplatResources) -> Void)?

    @State private var tileSplatResources: TileSplatResources?

    public init(
        splatCloud: SplatCloud<SparkSplat>,
        projection: any ProjectionProtocol,
        cameraMatrix: simd_float4x4,
        modelMatrix: simd_float4x4 = .identity,
        debugTileBorders: Bool = false,
        showHeatMap: Bool = false,
        onResourcesChanged: ((TileSplatResources) -> Void)? = nil
    ) {
        self.splatCloud = splatCloud
        self.projection = projection
        self.cameraMatrix = cameraMatrix
        self.modelMatrix = modelMatrix
        self.debugTileBorders = debugTileBorders
        self.showHeatMap = showHeatMap
        self.onResourcesChanged = onResourcesChanged
    }

    public var body: some View {
        RenderView { _, drawableSize in
            let drawableSizeFloat = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
            let resources = try ensureTileResources(size: drawableSize)
            let projectionMatrix = projection.projectionMatrix(aspectRatio: Float(drawableSize.width / drawableSize.height))

            // Pass 1a: Count splats per tile
            try TileBinningCountPass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: drawableSizeFloat,
                tileSplatResources: resources
            )

            // Pass 1b: Compute prefix sum of tile counts
            try TilePrefixSumComputePass(
                tileSplatResources: resources
            )

            // Pass 1c: Write splats to compacted buffer using offsets
            try TileBinningWritePass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: drawableSizeFloat,
                tileSplatResources: resources
            )

            // Pass 2: Per-Tile Sorting (compute) - sorts splats within each tile by depth
            try TileSortingComputePass(
                tileSplatResources: resources
            )

            // Pass 3: Tile Fragment Shader (render) - renders splats using imageblock
            try RenderPass {
                try TileSplatRenderPass(
                    splatCloud: splatCloud,
                    tileSplatResources: resources,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: drawableSizeFloat,
                    debugTileBorders: debugTileBorders
                )
            }
            .renderPassDescriptorModifier { descriptor in
                descriptor.tileWidth = Int(TILE_SIZE)
                descriptor.tileHeight = Int(TILE_SIZE)
                // half4 = 8 bytes, aligned to 16 bytes
                descriptor.imageblockSampleLength = 16
            }

            // Optional: Heatmap overlay showing splat density per tile
            if showHeatMap {
                try RenderPass {
                    try TileHeatMapRenderPass(tileSplatResources: resources, showTileBorders: debugTileBorders)
                }
            }

            // Copy tile counters to readback buffer for stats
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
        }
    }

    private func ensureTileResources(size: CGSize) throws -> TileSplatResources {
        let drawableSizeFloat = SIMD2<Float>(Float(size.width), Float(size.height))

        if let existing = tileSplatResources {
            if existing.needsResize(for: drawableSizeFloat) {
                try existing.resize(for: drawableSizeFloat)
            }
            onResourcesChanged?(existing)
            return existing
        }

        let device = _MTLCreateSystemDefaultDevice()
        let resources = try TileSplatResources(device: device, drawableSize: drawableSizeFloat)
        tileSplatResources = resources
        onResourcesChanged?(resources)
        return resources
    }
}

#endif

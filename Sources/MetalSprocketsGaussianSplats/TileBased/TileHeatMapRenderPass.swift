#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

/// Renders a heatmap overlay that shows the splat density per tile.
///
/// - Important: This type is part of the **experimental** tile-based renderer.
///   It can change or move in a future version.
struct TileHeatMapRenderPass: Element {
    var tileSplatResources: TileSplatResources
    var showTileBorders: Bool

    var shaderLibrary: ShaderNamespace

    @MSState
    var vertexShader: VertexShader
    @MSState
    var fragmentShader: FragmentShader
    /// Function-constant value baked into `fragmentShader`. The body recompiles
    /// the shader when this drifts from `showTileBorders`. Compile errors
    /// propagate instead of a crash.
    @MSState
    private var lastShowTileBorders: Bool?

    var vertexDescriptor: MTLVertexDescriptor

    init(tileSplatResources: TileSplatResources, showTileBorders: Bool = false) throws {
        self.tileSplatResources = tileSplatResources
        self.showTileBorders = showTileBorders

        self.shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
            .namespaced("TilePrefixSum")

        self.vertexShader = try shaderLibrary.function(named: "tile_heatmap_vertex", type: VertexShader.self)
        self.fragmentShader = try Self.makeFragmentShader(shaderLibrary: shaderLibrary, showTileBorders: showTileBorders)

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        self.vertexDescriptor = vertexDescriptor
    }

    private static func makeFragmentShader(shaderLibrary: ShaderNamespace, showTileBorders: Bool) throws -> FragmentShader {
        var fragmentConstants = FunctionConstants()
        fragmentConstants["showTileBorders"] = .bool(showTileBorders)
        return try shaderLibrary.function(named: "tile_heatmap_fragment", type: FragmentShader.self, constants: fragmentConstants)
    }

    /// Returns the fragment shader that matches the current `showTileBorders`.
    /// It recompiles the shader when the flag changed. Errors propagate to the
    /// caller instead of a crash.
    private func updatedFragmentShader() throws -> FragmentShader {
        if lastShowTileBorders != showTileBorders {
            fragmentShader = try Self.makeFragmentShader(shaderLibrary: shaderLibrary, showTileBorders: showTileBorders)
            lastShowTileBorders = showTileBorders
        }
        return fragmentShader
    }

    var body: some Element {
        get throws {
            let fragmentShader = try updatedFragmentShader()
            try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
                Draw { commandEncoder in
                    // Full-screen quad vertices in NDC.
                    let vertices: [SIMD2<Float>] = [
                        [-1, -1], [-1, 1], [1, -1], [1, 1]
                    ]
                    commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                    commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                .parameter("tileGridSize", value: tileSplatResources.tileGridSize)
                .parameter("tileCounters", buffer: tileSplatResources.tileCounters.unsafeMTLBuffer)
                .parameter("maxTileCount", buffer: tileSplatResources.maxTileCount.unsafeMTLBuffer)
                .parameter("drawableSize", value: tileSplatResources.drawableSize)
            }
            .vertexDescriptor(vertexDescriptor)
            .renderPipelineDescriptorTransformer { renderPipelineDescriptor in
                renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
                renderPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
                renderPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
                renderPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                renderPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                renderPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                renderPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        }
    }
}
#endif

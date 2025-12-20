#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

/// Render pass that uses Metal's native tile shading with imageblock
/// Two-pass approach:
/// 1. Fragment shader computes splat colors and writes to imageblock
/// 2. Blit shader reads from imageblock and outputs to color attachment
public struct TileSplatRenderPass: Element {
    // MARK: - Properties

    var splatCloud: GPUSplatCloud<SparkSplat>
    var tileSplatResources: TileSplatResources
    var projectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var cameraMatrix: simd_float4x4
    var debugTileBorders: Bool

    var shaderLibrary: ShaderNamespace

    @MSState
    var vertexShader: VertexShader
    @MSState
    var fragmentShader: FragmentShader
    @MSState
    var blitFragmentShader: FragmentShader

    // MARK: - Initialization

    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        tileSplatResources: TileSplatResources,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        debugTileBorders: Bool = false
    ) throws {
        self.splatCloud = splatCloud
        self.tileSplatResources = tileSplatResources
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.debugTileBorders = debugTileBorders

        self.shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
            .namespaced("TileSplatRender")
        self.vertexShader = try shaderLibrary.function(named: "tile_vertex", type: VertexShader.self)
        self.fragmentShader = try Self.makeFragmentShader(shaderLibrary: shaderLibrary, debugTileBorders: debugTileBorders)
        self.blitFragmentShader = try shaderLibrary.function(named: "tile_blit_fragment", type: FragmentShader.self)
    }

    private static func makeFragmentShader(shaderLibrary: ShaderNamespace, debugTileBorders: Bool) throws -> FragmentShader {
        var fragmentConstants = FunctionConstants()
        fragmentConstants["debugTileBorders"] = .bool(debugTileBorders)
        return try shaderLibrary.function(named: "tile_fragment", type: FragmentShader.self, constants: fragmentConstants)
    }

    // MARK: - Element Body

    public var body: some Element {
        get throws {
            let uniforms = tileSplatResources.makeUniforms(
                modelMatrix: modelMatrix,
                viewMatrix: cameraMatrix.inverse,
                projectionMatrix: projectionMatrix
            )

            // Full-screen triangle (more efficient than quad)
            let vertices: [SIMD2<Float>] = [
                [-1, -1],
                [ 3, -1],
                [-1, 3]
            ]

            // Step 1: Render splats to imageblock (no color output)
            try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
                Draw { commandEncoder in
                    commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)

                    // Fragment shader buffers
                    commandEncoder.setFragmentBuffer(splatCloud.splats.unsafeMTLBuffer, offset: 0, index: 0)
                    commandEncoder.setFragmentBuffer(tileSplatResources.tileSplatIndicesA.unsafeMTLBuffer, offset: 0, index: 1)
                    commandEncoder.setFragmentBuffer(tileSplatResources.tileOffsets.unsafeMTLBuffer, offset: 0, index: 2)

                    // Uniforms
                    var uniformsCopy = uniforms
                    commandEncoder.setFragmentBytes(&uniformsCopy, length: MemoryLayout<TileRenderUniforms>.size, index: 3)

                    commandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
            }
            .onChange(of: debugTileBorders, initial: true) { _, _ in
                fragmentShader = try! Self.makeFragmentShader(shaderLibrary: shaderLibrary, debugTileBorders: debugTileBorders)
            }

            // Step 2: Blit imageblock to color attachment (framebuffer)
            // No blending needed - tile shader does all blending internally
            try RenderPipeline(vertexShader: vertexShader, fragmentShader: blitFragmentShader) {
                Draw { commandEncoder in
                    commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                    commandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
            }
        }
    }
}

#endif

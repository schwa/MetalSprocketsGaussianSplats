#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

public struct TileHeatMapRenderPipeline: Element {
    var tileGridSize: SIMD2<UInt32>
    var tileCounts: TypedMTLBuffer<UInt32>
    var maxCountBuffer: TypedMTLBuffer<UInt32>

    @MSState
    var vertexShader: VertexShader
    @MSState
    var fragmentShader: FragmentShader

    var vertexDescriptor: MTLVertexDescriptor

    public init(tileGridSize: SIMD2<UInt32>, tileCounts: TypedMTLBuffer<UInt32>, maxCountBuffer: TypedMTLBuffer<UInt32>) throws {
        self.tileGridSize = tileGridSize
        self.tileCounts = tileCounts
        self.maxCountBuffer = maxCountBuffer

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders()).namespaced("GaussianSplatDebug")

        self.vertexShader = try shaderLibrary.function(named: "tile_heatmap_vertex", type: VertexShader.self)
        self.fragmentShader = try shaderLibrary.function(named: "tile_heatmap_fragment", type: FragmentShader.self)

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        self.vertexDescriptor = vertexDescriptor
    }

    public var body: some Element {
        get throws {
            try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
                Draw { commandEncoder in
                    // Full-screen quad vertices in NDC
                    let vertices: [SIMD2<Float>] = [
                        [-1, -1], [-1, 1], [1, -1], [1, 1]
                    ]
                    commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                    commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                .parameter("tileGridSize", value: tileGridSize)
                .parameter("tileCounts", buffer: tileCounts.unsafeMTLBuffer)
                .parameter("maxCount", buffer: maxCountBuffer.unsafeMTLBuffer)
            }
            .vertexDescriptor(vertexDescriptor)
            .renderPipelineDescriptorModifier { renderPipelineDescriptor in
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

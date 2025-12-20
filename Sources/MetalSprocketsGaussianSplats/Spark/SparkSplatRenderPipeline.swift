#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

public struct SparkSplatRenderPipeline: Element {
    var splatCloud: GPUSplatCloud<SparkSplat>
    var projectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var cameraMatrix: simd_float4x4
    var drawableSize: SIMD2<Float>

    @MSState
    private var sortManager: AsyncSortManager<SparkSplat>?
    @MSState
    var vertexShader: VertexShader
    @MSState
    var fragmentShader: FragmentShader
    var vertexDescriptor: MTLVertexDescriptor

    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>, convertSRGBToLinear: Bool = true) throws {
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize

        // Load Spark shaders
        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SparkSplatRenderShader")

        var vertexConstants = FunctionConstants()
        vertexConstants["use_sh"] = .bool(splatCloud.shCoefficients != nil)

        var fragmentConstants = FunctionConstants()
        fragmentConstants["convert_srgb_to_linear"] = .bool(convertSRGBToLinear)

        self.vertexShader = try shaderLibrary.function(named: "vertex_main", type: VertexShader.self, constants: vertexConstants)
        self.fragmentShader = try shaderLibrary.function(named: "fragment_main", type: FragmentShader.self, constants: fragmentConstants)

        // Setup vertex descriptor
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        self.vertexDescriptor = vertexDescriptor
    }

    public var body: some Element {
        get throws {
            let shBuffer = splatCloud.shCoefficients
            let degree = splatCloud.shDegree
            try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
                Draw { commandEncoder in
                    let vertices: [SIMD2<Float>] = [
                        [-1, -1], [-1, 1], [1, -1], [1, 1]
                    ]
                    commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                    // Set SH buffer and degree if available (buffer indices 11, 12 match shader)
                    if let buffer = shBuffer {
                        var shDegreeValue = UInt32(degree)
                        commandEncoder.setVertexBytes(&shDegreeValue, length: MemoryLayout<UInt32>.size, index: 11)
                        commandEncoder.setVertexBuffer(buffer.unsafeMTLBuffer, offset: 0, index: 12)
                    }
                    commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splatCloud.count)
                }
                .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
                .parameter("indexedDistances", buffer: splatCloud.indexedDistances.indices.unsafeMTLBuffer)
                .parameter("modelMatrix", value: modelMatrix)
                .parameter("viewMatrix", value: cameraMatrix.inverse)
                .parameter("projectionMatrix", value: projectionMatrix)
                .parameter("drawableSize", value: drawableSize)
                .parameter("scale", value: Float(2.0))
                .parameter("cameraPosition", value: SIMD3<Float>(cameraMatrix.columns.3.x, cameraMatrix.columns.3.y, cameraMatrix.columns.3.z))
            }
            .vertexDescriptor(vertexDescriptor)
            .renderPipelineDescriptorModifier { renderPipelineDescriptor in
                renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
                renderPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
                renderPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
                renderPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                renderPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                renderPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                renderPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            .onChange(of: splatCloud, initial: true) { _, _ in
                let newSortManager = try! AsyncSortManager(device: _MTLCreateSystemDefaultDevice(), splatCloud: splatCloud, capacity: splatCloud.count, logger: logger)
                sortManager = newSortManager
                nonisolated(unsafe) var splatCloudRef = splatCloud
                Task { @MainActor [sortManager = newSortManager, logger] in
                    let channel = await sortManager.sortedIndicesChannel()
                    for await sort in channel {
                        if sort.parameters.time < splatCloudRef.indexedDistances.parameters.time {
                            logger?.error("Out of order sort")
                            return
                        }

                        splatCloudRef.indexedDistances = sort
                    }
                }
                requestSort()
            }
            .onChange(of: cameraMatrix) {
                requestSort()
            }
        }
    }

    func requestSort() {
        guard let sortManager else {
            fatalError("No sort manager")
        }
        let parameters = SortParameters(camera: cameraMatrix, model: modelMatrix)
        sortManager.requestSort(parameters)
    }
}

#endif

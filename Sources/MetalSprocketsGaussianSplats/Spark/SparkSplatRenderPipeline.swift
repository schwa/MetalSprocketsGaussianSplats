#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

public struct SparkSplatRenderPipeline: Element {
    var splatCloud: GPUSplatCloud<SparkSplat>
    var projectionMatrices: [simd_float4x4]
    var modelMatrix: simd_float4x4
    var cameraMatrices: [simd_float4x4]
    var drawableSize: SIMD2<Float>

    @MSState
    private var sortManager: AsyncSortManager<SparkSplat>?
    @MSState
    var vertexShader: VertexShader
    @MSState
    var fragmentShader: FragmentShader
    var vertexDescriptor: MTLVertexDescriptor

    /// Convenience initializer for single-view rendering (non-stereo)
    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>, convertSRGBToLinear: Bool = true) throws {
        try self.init(
            splatCloud: splatCloud,
            projectionMatrices: [projectionMatrix],
            modelMatrix: modelMatrix,
            cameraMatrices: [cameraMatrix],
            drawableSize: drawableSize,
            convertSRGBToLinear: convertSRGBToLinear
        )
    }

    /// Full initializer supporting stereo/amplification rendering
    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrices: [simd_float4x4], modelMatrix: simd_float4x4, cameraMatrices: [simd_float4x4], drawableSize: SIMD2<Float>, convertSRGBToLinear: Bool = true) throws {
        precondition(projectionMatrices.count == cameraMatrices.count, "projectionMatrices and cameraMatrices must have the same count")
        precondition(!projectionMatrices.isEmpty, "Must have at least one projection matrix")
        self.splatCloud = splatCloud
        self.projectionMatrices = projectionMatrices
        self.modelMatrix = modelMatrix
        self.cameraMatrices = cameraMatrices
        self.drawableSize = drawableSize

        // Load Spark shaders
        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SparkSplatRenderShader")

        let useSH = splatCloud.shCoefficients != nil
        logger?.info("SparkSplatRenderPipeline: SH enabled=\(useSH), degree=\(splatCloud.shDegree)")

        var vertexConstants = FunctionConstants()
        vertexConstants["use_sh"] = .bool(useSH)

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

            // Compute view matrices (inverse of camera matrices)
            let viewMatrices = cameraMatrices.map(\.inverse)

            // Extract camera positions from camera matrices
            let cameraPositions = cameraMatrices.map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }

            // Amplification count for stereo rendering
            let amplificationCount = cameraMatrices.count

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
                    // Enable vertex amplification for stereo rendering
                    commandEncoder.setVertexAmplificationCount(amplificationCount, viewMappings: nil)
                    commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splatCloud.count)
                }
                .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
                .parameter("indexedDistances", buffer: splatCloud.indexedDistances.indices.unsafeMTLBuffer)
                .parameter("modelMatrix", value: modelMatrix)
                .parameter("viewMatrices", values: viewMatrices)
                .parameter("projectionMatrices", values: projectionMatrices)
                .parameter("drawableSize", value: drawableSize)
                .parameter("scale", value: Float(2.0))
                .parameter("cameraPositions", values: cameraPositions)
            }
            .vertexDescriptor(vertexDescriptor)
            .renderPipelineDescriptorModifier { [amplificationCount] renderPipelineDescriptor in
                renderPipelineDescriptor.inputPrimitiveTopology = .triangle
                renderPipelineDescriptor.maxVertexAmplificationCount = amplificationCount
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
            .onChange(of: cameraMatrices) {
                requestSort()
            }
        }
    }

    func requestSort() {
        guard let sortManager else {
            fatalError("No sort manager")
        }
        // Use average camera position for sorting (works for both mono and stereo)
        let averageCameraMatrix: simd_float4x4
        if cameraMatrices.count == 1 {
            averageCameraMatrix = cameraMatrices[0]
        } else {
            // Average the translation columns of all camera matrices
            var avgPosition = SIMD3<Float>.zero
            for matrix in cameraMatrices {
                avgPosition += SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
            }
            avgPosition /= Float(cameraMatrices.count)
            // Use the first camera's orientation with averaged position
            var avgMatrix = cameraMatrices[0]
            avgMatrix.columns.3 = SIMD4<Float>(avgPosition, 1.0)
            averageCameraMatrix = avgMatrix
        }
        let parameters = SortParameters(camera: averageCameraMatrix, model: modelMatrix)
        sortManager.requestSort(parameters)
    }
}

#endif

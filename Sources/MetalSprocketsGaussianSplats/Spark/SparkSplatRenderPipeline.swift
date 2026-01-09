#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import Splats

// MARK: - Element Extension for Multiple Resources

extension Element {
    /// Mark multiple resources as in use for argument buffer access
    func useResources(_ resources: [any MTLResource], usage: MTLResourceUsage, stages: MTLRenderStages) -> some Element {
        onWorkloadEnter { environmentValues in
            let renderCommandEncoder = environmentValues.renderCommandEncoder.orFatalError("Missing render command encoder")
            for resource in resources {
                renderCommandEncoder.useResource(resource, usage: usage, stages: stages)
            }
        }
    }
}

public struct SparkSplatRenderPipeline: Element {
    var splatClouds: [GPUSplatCloud<SparkSplat>]
    var projectionMatrices: [simd_float4x4]
    var modelMatrix: simd_float4x4
    var cameraMatrices: [simd_float4x4]
    var drawableSize: SIMD2<Float>
    var useSphericalHarmonics: Bool

    @MSState
    private var sortManager: AsyncSortManager<SparkSplat>?
    @MSState
    private var sortedIndices: SplatIndices?
    @MSState
    var vertexShader: VertexShader
    @MSState
    var fragmentShader: FragmentShader
    var vertexDescriptor: MTLVertexDescriptor

    /// Total splat count across all clouds
    var totalSplatCount: Int {
        splatClouds.reduce(0) { $0 + $1.count }
    }

    // MARK: - Single Cloud Convenience Initializers

    /// Convenience initializer for single cloud, single-view rendering (non-stereo)
    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>, convertSRGBToLinear: Bool = true, useSphericalHarmonics: Bool? = nil) throws {
        try self.init(
            splatClouds: [splatCloud],
            projectionMatrices: [projectionMatrix],
            modelMatrix: modelMatrix,
            cameraMatrices: [cameraMatrix],
            drawableSize: drawableSize,
            convertSRGBToLinear: convertSRGBToLinear,
            useSphericalHarmonics: useSphericalHarmonics
        )
    }

    /// Convenience initializer for single cloud, stereo/amplification rendering
    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrices: [simd_float4x4], modelMatrix: simd_float4x4, cameraMatrices: [simd_float4x4], drawableSize: SIMD2<Float>, convertSRGBToLinear: Bool = true, useSphericalHarmonics: Bool? = nil) throws {
        try self.init(
            splatClouds: [splatCloud],
            projectionMatrices: projectionMatrices,
            modelMatrix: modelMatrix,
            cameraMatrices: cameraMatrices,
            drawableSize: drawableSize,
            convertSRGBToLinear: convertSRGBToLinear,
            useSphericalHarmonics: useSphericalHarmonics
        )
    }

    // MARK: - Multi-Cloud Initializers

    /// Full initializer supporting multiple clouds and stereo/amplification rendering
    /// - Parameter useSphericalHarmonics: Override SH usage. If nil, automatically enables SH when any cloud has SH data.
    public init(splatClouds: [GPUSplatCloud<SparkSplat>], projectionMatrices: [simd_float4x4], modelMatrix: simd_float4x4, cameraMatrices: [simd_float4x4], drawableSize: SIMD2<Float>, convertSRGBToLinear: Bool = true, useSphericalHarmonics: Bool? = nil) throws {
        precondition(projectionMatrices.count == cameraMatrices.count, "projectionMatrices and cameraMatrices must have the same count")
        precondition(!projectionMatrices.isEmpty, "Must have at least one projection matrix")
        precondition(!splatClouds.isEmpty, "Must have at least one splat cloud")

        self.splatClouds = splatClouds
        self.projectionMatrices = projectionMatrices
        self.modelMatrix = modelMatrix
        self.cameraMatrices = cameraMatrices
        self.drawableSize = drawableSize

        // Determine if SH should be used: explicit override, or auto-detect from any cloud having SH data
        let hasSHData = splatClouds.contains { $0.shCoefficients != nil }
        let useSH = useSphericalHarmonics ?? hasSHData
        let effectiveUseSH = useSH && hasSHData
        self.useSphericalHarmonics = effectiveUseSH

        // Load Spark shaders - use multi-cloud shader if more than one cloud
        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SparkSplatRenderShader")

        var vertexConstants = FunctionConstants()
        vertexConstants["use_sh"] = .bool(effectiveUseSH)

        var fragmentConstants = FunctionConstants()
        fragmentConstants["convert_srgb_to_linear"] = .bool(convertSRGBToLinear)

        let vertexShaderName = splatClouds.count > 1 ? "vertex_main_multicloud" : "vertex_main"
        self.vertexShader = try shaderLibrary.function(named: vertexShaderName, type: VertexShader.self, constants: vertexConstants)
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
            // Compute view matrices (inverse of camera matrices)
            let viewMatrices = cameraMatrices.map(\.inverse)

            // Extract camera positions from camera matrices
            let cameraPositions = cameraMatrices.map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }

            // Amplification count for stereo rendering
            let amplificationCount = cameraMatrices.count

            let isMultiCloud = splatClouds.count > 1

            try Group {
                if let indexedDistancesBuffer = sortedIndices?.indices {
                    if isMultiCloud {
                        try multiCloudRenderPipeline(
                            indexedDistancesBuffer: indexedDistancesBuffer,
                            viewMatrices: viewMatrices,
                            cameraPositions: cameraPositions,
                            amplificationCount: amplificationCount
                        )
                    } else {
                        try singleCloudRenderPipeline(
                            indexedDistancesBuffer: indexedDistancesBuffer,
                            viewMatrices: viewMatrices,
                            cameraPositions: cameraPositions,
                            amplificationCount: amplificationCount
                        )
                    }
                }
            }
            .onChange(of: splatClouds, initial: true) { _, _ in
                // Do a synchronous initial sort so we have content immediately
                let device = _MTLCreateSystemDefaultDevice()
                let initialSort: SplatIndices
                if splatClouds.count == 1 {
                    initialSort = try! CPUSplatRadixSorter.sort(
                        device: device,
                        splats: splatClouds[0].splats,
                        camera: cameraMatrices[0],
                        model: modelMatrix * splatClouds[0].modelTransform,
                        reversed: false
                    )
                } else {
                    initialSort = try! CPUSplatRadixSorter.sort(
                        device: device,
                        clouds: splatClouds,
                        camera: cameraMatrices[0],
                        sceneModel: modelMatrix,
                        reversed: false
                    )
                }
                sortedIndices = initialSort

                // Now set up the async sort manager for subsequent updates
                let newSortManager = try! AsyncSortManager(device: device, splatClouds: splatClouds, capacity: totalSplatCount, logger: logger)
                sortManager = newSortManager
                nonisolated(unsafe) var sortedIndicesRef = _sortedIndices
                Task { @MainActor [sortManager = newSortManager, logger] in
                    let channel = await sortManager.sortedIndicesChannel()
                    var lastSortTime: TimeInterval = 0
                    for await sort in channel {
                        if sort.parameters.time < lastSortTime {
                            logger?.error("Out of order sort")
                            continue
                        }
                        lastSortTime = sort.parameters.time
                        sortedIndicesRef.wrappedValue = sort
                    }
                }
            }
            .onChange(of: cameraMatrices) {
                requestSort()
            }
        }
    }

    // MARK: - Single Cloud Render Pipeline

    private func singleCloudRenderPipeline(
        indexedDistancesBuffer: TypedMTLBuffer<IndexedDistance>,
        viewMatrices: [simd_float4x4],
        cameraPositions: [SIMD3<Float>],
        amplificationCount: Int
    ) throws -> some Element {
        let splatCloud = splatClouds[0]
        let shBuffer = useSphericalHarmonics ? splatCloud.shCoefficients : nil
        let degree = useSphericalHarmonics ? splatCloud.shDegree : 0
        let combinedModelMatrix = modelMatrix * splatCloud.modelTransform

        return try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
            Draw { commandEncoder in
                let vertices: [SIMD2<Float>] = [
                    [-1, -1], [-1, 1], [1, -1], [1, 1]
                ]
                commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                if let buffer = shBuffer {
                    var shDegreeValue = UInt32(degree)
                    commandEncoder.setVertexBytes(&shDegreeValue, length: MemoryLayout<UInt32>.size, index: 11)
                    commandEncoder.setVertexBuffer(buffer.unsafeMTLBuffer, offset: 0, index: 12)
                }
                commandEncoder.setVertexAmplificationCount(amplificationCount, viewMappings: nil)
                commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splatCloud.count)
            }
            .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
            .parameter("indexedDistances", buffer: indexedDistancesBuffer.unsafeMTLBuffer)
            .parameter("modelMatrix", value: combinedModelMatrix)
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
    }

    // MARK: - Multi-Cloud Render Pipeline

    private func multiCloudRenderPipeline(
        indexedDistancesBuffer: TypedMTLBuffer<IndexedDistance>,
        viewMatrices: [simd_float4x4],
        cameraPositions: [SIMD3<Float>],
        amplificationCount: Int
    ) throws -> some Element {
        let device = _MTLCreateSystemDefaultDevice()

        // Build per-cloud data array
        var cloudDataArray: [SplatCloudData] = []
        for cloud in splatClouds {
            let combinedModel = modelMatrix * cloud.modelTransform
            let cloudData = SplatCloudData(
                splats: cloud.splats.unsafeMTLBuffer.gpuAddressAsUnsafeMutablePointer(type: SparkSplat.self),
                modelMatrix: combinedModel,
                shCoefficients: cloud.shCoefficients?.unsafeMTLBuffer.gpuAddressAsUnsafeMutablePointer(type: Float.self)
            )
            cloudDataArray.append(cloudData)
        }

        // Create buffer for cloud data array
        let cloudDataBuffer = try device.makeTypedBuffer(values: cloudDataArray, options: [])

        // Create the argument buffer struct
        let argumentBuffer = MultiCloudArgumentBuffer(
            cloudCount: UInt32(splatClouds.count),
            clouds: cloudDataBuffer.unsafeMTLBuffer.gpuAddressAsUnsafeMutablePointer(type: SplatCloudData.self)
        )

        // Get max SH degree across all clouds
        let maxSHDegree = splatClouds.compactMap { $0.shCoefficients != nil ? $0.shDegree : nil }.max() ?? 0

        // Build element with useResource for all cloud buffers
        // Collect all resources that need to be marked as in use
        var resourcesToUse: [MTLResource] = [cloudDataBuffer.unsafeMTLBuffer]
        for cloud in splatClouds {
            resourcesToUse.append(cloud.splats.unsafeMTLBuffer)
            if let shBuffer = cloud.shCoefficients {
                resourcesToUse.append(shBuffer.unsafeMTLBuffer)
            }
        }

        return try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
            Draw { [argumentBuffer, maxSHDegree] commandEncoder in
                let vertices: [SIMD2<Float>] = [
                    [-1, -1], [-1, 1], [1, -1], [1, 1]
                ]
                commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                // Set SH degree for multi-cloud (shader will look up per-cloud SH buffers)
                if useSphericalHarmonics {
                    var shDegreeValue = UInt32(maxSHDegree)
                    commandEncoder.setVertexBytes(&shDegreeValue, length: MemoryLayout<UInt32>.size, index: 11)
                }
                commandEncoder.setVertexAmplificationCount(amplificationCount, viewMappings: nil)
                commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: totalSplatCount)
            }
            .parameter("indexedDistances", buffer: indexedDistancesBuffer.unsafeMTLBuffer)
            .parameter("viewMatrices", values: viewMatrices)
            .parameter("projectionMatrices", values: projectionMatrices)
            .parameter("drawableSize", value: drawableSize)
            .parameter("scale", value: Float(2.0))
            .parameter("cameraPositions", values: cameraPositions)
            .parameter("clouds", value: argumentBuffer)
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
        .useResources(resourcesToUse, usage: .read, stages: .vertex)
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
            var avgPosition = SIMD3<Float>.zero
            for matrix in cameraMatrices {
                avgPosition += SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
            }
            avgPosition /= Float(cameraMatrices.count)
            var avgMatrix = cameraMatrices[0]
            avgMatrix.columns.3 = SIMD4<Float>(avgPosition, 1.0)
            averageCameraMatrix = avgMatrix
        }
        // Pass only the scene-level modelMatrix; sorter combines with cloud.modelTransform
        let parameters = SortParameters(camera: averageCameraMatrix, model: modelMatrix)
        sortManager.requestSort(parameters)
    }
}

#endif

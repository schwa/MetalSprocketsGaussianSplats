#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSupport
import Splats

/// A MetalSprockets render pipeline for Gaussian splats using the Spark renderer.
///
/// This pipeline is a pure rendering element — it does not manage sorting. The caller
/// is responsible for creating an ``AsyncSortManager``, subscribing to its
/// ``AsyncSortManager/sortedIndicesStream``, requesting sorts when the camera or model
/// changes, and passing the resulting ``SplatIndices`` into the pipeline.
///
/// ## Interactive Rendering (SwiftUI)
///
/// ```swift
/// @State private var sortedIndices: SplatIndices?
///
/// var body: some View {
///     RenderView { _, drawableSize in
///         if let sortedIndices {
///             try RenderPass {
///                 try SparkSplatRenderPipeline(
///                     splatCloud: cloud,
///                     projectionMatrix: projectionMatrix,
///                     modelMatrix: .identity,
///                     cameraMatrix: cameraMatrix,
///                     drawableSize: SIMD2<Float>(drawableSize),
///                     sortedIndices: sortedIndices
///                 )
///             }

///         }
///     }
///     .task {
///         for await indices in sortManager.sortedIndicesStream {
///             sortedIndices = indices
///         }
///     }
///     .onChange(of: cameraMatrix, initial: true) {
///         sortManager.requestSort(SortParameters(camera: cameraMatrix, model: .identity))
///     }
/// }
/// ```
///
/// ## Buffer Pooling
///
/// The ``AsyncSortManager`` uses an internal buffer pool for index buffers. To enable
/// buffer reuse and reduce allocations, release old indices when receiving new ones:
///
/// ```swift
/// for await indices in sortManager.sortedIndicesStream {
///     if let old = sortedIndices {
///         sortManager.release(old)
///     }
///     sortedIndices = indices
/// }
/// ```
///
/// ## Offline / Single-Frame Rendering
///
/// ```swift
/// let sortedIndices = sortManager.sortNowSync(sortParameters)
/// let renderPass = try RenderPass {
///     try SparkSplatRenderPipeline(
///         splatCloud: cloud,
///         projectionMatrix: projectionMatrix,
///         modelMatrix: .identity,
///         cameraMatrix: cameraMatrix,
///         drawableSize: drawableSize,
///         sortedIndices: sortedIndices
///     )
/// }
/// // For offline rendering, release after render:
/// sortManager.release(sortedIndices)
/// ```
///
/// Supports single or multiple splat clouds, mono and stereo rendering,
/// optional spherical harmonics, and bounding box culling.
public struct SparkSplatRenderPipeline: Element {
    var splatClouds: [GPUSplatCloud<SparkSplat>]
    var projectionMatrices: [simd_float4x4]
    var modelMatrix: simd_float4x4
    var cameraMatrices: [simd_float4x4]
    var drawableSize: SIMD2<Float>
    var useSphericalHarmonics: Bool
    var boundingBox: BoundingBox3D?
    var sortedIndices: SplatIndices
    @MSState
    var vertexShader: VertexShader
    @MSState
    var fragmentShader: FragmentShader
    @MSState
    private var lastUseBoundingBox: Bool = false
    var vertexDescriptor: MTLVertexDescriptor
    var convertSRGBToLinear: Bool

    /// Total splat count across all clouds
    var totalSplatCount: Int {
        splatClouds.reduce(0) { $0 + $1.count }
    }

    // MARK: - Single Cloud Convenience Initializers

    /// Convenience initializer for single cloud, single-view rendering (non-stereo)
    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>, convertSRGBToLinear: Bool = true, useSphericalHarmonics: Bool? = nil, boundingBox: BoundingBox3D? = nil, sortedIndices: SplatIndices) throws {
        try self.init(
            splatClouds: [splatCloud],
            projectionMatrices: [projectionMatrix],
            modelMatrix: modelMatrix,
            cameraMatrices: [cameraMatrix],
            drawableSize: drawableSize,
            convertSRGBToLinear: convertSRGBToLinear,
            useSphericalHarmonics: useSphericalHarmonics,
            boundingBox: boundingBox,
            sortedIndices: sortedIndices
        )
    }

    /// Convenience initializer for single cloud, stereo/amplification rendering
    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrices: [simd_float4x4], modelMatrix: simd_float4x4, cameraMatrices: [simd_float4x4], drawableSize: SIMD2<Float>, convertSRGBToLinear: Bool = true, useSphericalHarmonics: Bool? = nil, boundingBox: BoundingBox3D? = nil, sortedIndices: SplatIndices) throws {
        try self.init(
            splatClouds: [splatCloud],
            projectionMatrices: projectionMatrices,
            modelMatrix: modelMatrix,
            cameraMatrices: cameraMatrices,
            drawableSize: drawableSize,
            convertSRGBToLinear: convertSRGBToLinear,
            useSphericalHarmonics: useSphericalHarmonics,
            boundingBox: boundingBox,
            sortedIndices: sortedIndices
        )
    }

    // MARK: - Multi-Cloud Initializers

    /// Full initializer supporting multiple clouds and stereo/amplification rendering
    /// - Parameter useSphericalHarmonics: Override SH usage. If nil, automatically enables SH when any cloud has SH data.
    /// - Parameter boundingBox: Optional world-space bounding box. Splats outside this box are culled.
    /// - Parameter sortedIndices: Pre-sorted splat indices from an ``AsyncSortManager``.
    public init(splatClouds: [GPUSplatCloud<SparkSplat>], projectionMatrices: [simd_float4x4], modelMatrix: simd_float4x4, cameraMatrices: [simd_float4x4], drawableSize: SIMD2<Float>, convertSRGBToLinear: Bool = true, useSphericalHarmonics: Bool? = nil, boundingBox: BoundingBox3D? = nil, sortedIndices: SplatIndices) throws {
        precondition(projectionMatrices.count == cameraMatrices.count, "projectionMatrices and cameraMatrices must have the same count")
        precondition(!projectionMatrices.isEmpty, "Must have at least one projection matrix")
        precondition(!splatClouds.isEmpty, "Must have at least one splat cloud")

        self.splatClouds = splatClouds
        self.projectionMatrices = projectionMatrices
        self.modelMatrix = modelMatrix
        self.cameraMatrices = cameraMatrices
        self.drawableSize = drawableSize
        self.boundingBox = boundingBox
        self.convertSRGBToLinear = convertSRGBToLinear
        self.sortedIndices = sortedIndices

        // Determine if SH should be used: explicit override, or auto-detect from any cloud having SH data
        let hasSHData = splatClouds.contains { $0.shCoefficients != nil }
        let useSH = useSphericalHarmonics ?? hasSHData
        let effectiveUseSH = useSH && hasSHData
        self.useSphericalHarmonics = effectiveUseSH

        // Load Spark shaders - use multi-cloud shader if more than one cloud
        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SparkSplatRenderShader")

        var vertexConstants = FunctionConstants()
        vertexConstants["use_sh"] = .bool(effectiveUseSH)
        vertexConstants["use_bounding_box"] = .bool(boundingBox != nil)

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
            try Group {
                try renderPipeline(sortedIndices: sortedIndices)
            }
            .onChange(of: boundingBox != nil, initial: true) { _, useBoundingBox in
                // Recreate shaders when bounding box presence changes (function constant changes)
                if useBoundingBox != lastUseBoundingBox {
                    lastUseBoundingBox = useBoundingBox
                    do {
                        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SparkSplatRenderShader")

                        var vertexConstants = FunctionConstants()
                        vertexConstants["use_sh"] = .bool(useSphericalHarmonics)
                        vertexConstants["use_bounding_box"] = .bool(useBoundingBox)

                        var fragmentConstants = FunctionConstants()
                        fragmentConstants["convert_srgb_to_linear"] = .bool(convertSRGBToLinear)

                        vertexShader = try shaderLibrary.function(named: "vertex_main", type: VertexShader.self, constants: vertexConstants)
                        fragmentShader = try shaderLibrary.function(named: "fragment_main", type: FragmentShader.self, constants: fragmentConstants)
                    } catch {
                        fatalError("Failed to recreate shaders: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Render Pipeline

    private func renderPipeline(sortedIndices: SplatIndices) throws -> some Element {
        let viewMatrices = cameraMatrices.map(\.inverse)
        let cameraPositions = cameraMatrices.map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        let amplificationCount = cameraMatrices.count
        let device = _MTLCreateSystemDefaultDevice()

        // Build per-cloud data array
        var cloudDataArray: [SplatCloudData] = []
        for cloud in splatClouds {
            let combinedModel = modelMatrix * cloud.modelTransform
            let cloudData = SplatCloudData(
                splats: cloud.splats.unsafeMTLBuffer.gpuAddressAsUnsafeMutablePointer(type: SparkSplat.self),
                modelMatrix: combinedModel,
                shCoefficients: cloud.shCoefficients?.unsafeMTLBuffer.gpuAddressAsUnsafeMutablePointer(type: Float.self),
                opacity: cloud.opacity
            )
            cloudDataArray.append(cloudData)
        }

        // Create buffer for cloud data array
        let cloudDataBuffer = try device.makeTypedBuffer(values: cloudDataArray, options: []).labeled("CloudData")

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
            Draw { [argumentBuffer, maxSHDegree, boundingBox] commandEncoder in
                let vertices: [SIMD2<Float>] = [
                    [-1, -1], [-1, 1], [1, -1], [1, 1]
                ]
                commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                // Set SH degree for multi-cloud (shader will look up per-cloud SH buffers)
                if useSphericalHarmonics {
                    var shDegreeValue = UInt32(maxSHDegree)
                    commandEncoder.setVertexBytes(&shDegreeValue, length: MemoryLayout<UInt32>.size, index: 11)
                }
                // Set bounding box for vertex culling
                if var bbox = boundingBox {
                    commandEncoder.setVertexBytes(&bbox, length: MemoryLayout<BoundingBox3D>.size, index: 12)
                }
                commandEncoder.setVertexAmplificationCount(amplificationCount, viewMappings: nil)
                commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: totalSplatCount)
            }
            .parameter("indexedDistances", buffer: sortedIndices.indices.unsafeMTLBuffer)
            .parameter("viewMatrices", values: viewMatrices)
            .parameter("projectionMatrices", values: projectionMatrices)
            .parameter("drawableSize", value: drawableSize)
            .parameter("scale", value: Float(2.0))
            .parameter("cameraPositions", values: cameraPositions)
            .parameter("clouds", value: argumentBuffer)
        }
        .vertexDescriptor(vertexDescriptor)
        .renderPassDescriptorModifier { [amplificationCount] descriptor in
            if amplificationCount == 1 {
                descriptor.renderTargetArrayLength = 1
            }
        }
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
}

// MARK: - Buffer Release Modifier

#endif

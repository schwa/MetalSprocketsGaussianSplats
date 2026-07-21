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
/// ``AsyncSortManager/managedSortedIndicesStream(pendingReleaseDepth:)``, requesting sorts when the camera or model
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
///         for await indices in sortManager.managedSortedIndicesStream() {
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
/// The ``AsyncSortManager`` uses an internal buffer pool for index buffers.
/// ``AsyncSortManager/managedSortedIndicesStream(pendingReleaseDepth:)`` releases
/// superseded buffers back to the pool automatically. For manual control, use
/// ``AsyncSortManager/sortedIndicesStream`` and release old indices yourself:
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
    /// Function-constant value baked into the current shaders. Body recompiles
    /// them when this drifts from `boundingBox != nil`, propagating compile
    /// errors instead of crashing.
    @MSState
    private var lastUseBoundingBox: Bool?
    /// Cached per-cloud argument data, rebuilt only when the clouds or model
    /// matrix change. Body can be evaluated many times per frame, so
    /// allocating here per evaluation was churning a fresh MTLBuffer each
    /// time. A changed key allocates a *new* buffer (never mutates the old
    /// one) so in-flight frames keep reading valid data.
    @MSState
    private var cloudDataCache: CloudDataCache?

    struct CloudDataCache {
        var modelMatrix: simd_float4x4
        var clouds: [GPUSplatCloud<SparkSplat>]
        var buffer: TypedMTLBuffer<SplatCloudData>
    }
    var vertexDescriptor: MTLVertexDescriptor
    var convertSRGBToLinear: Bool
    /// Optional vertex amplification view mappings, applied when setting the
    /// amplification count. Use ``viewMappings(_:)`` for per-eye rendering into
    /// specific layers of a layered render target.
    var amplificationViewMappings: [MTLVertexAmplificationViewMapping]?

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
    ///
    /// - Parameters:
    ///   - splatClouds: The splat clouds to render, in draw order.
    ///   - projectionMatrices: One projection matrix per view (two for stereo).
    ///   - modelMatrix: The scene-level model transform, combined with each cloud's own transform.
    ///   - cameraMatrices: One camera (view-to-world) matrix per view, matching `projectionMatrices`.
    ///   - drawableSize: The render target size in pixels.
    ///   - convertSRGBToLinear: Whether splat colors are converted from sRGB to linear in the shader.
    ///   - useSphericalHarmonics: Override SH usage. If nil, automatically enables SH when any cloud has SH data.
    ///   - boundingBox: Optional world-space bounding box. Splats outside this box are culled.
    ///   - sortedIndices: Pre-sorted splat indices from an ``AsyncSortManager``.
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
            let shaders = try updatedShaders()
            try Group {
                try renderPipeline(sortedIndices: sortedIndices, vertexShader: shaders.vertex, fragmentShader: shaders.fragment)
            }
        }
    }

    /// Returns shaders matching the current bounding-box presence, recompiling
    /// them when the `use_bounding_box` function constant changed. Errors
    /// propagate to the caller instead of crashing.
    private func updatedShaders() throws -> (vertex: VertexShader, fragment: FragmentShader) {
        let useBoundingBox = boundingBox != nil
        if lastUseBoundingBox != useBoundingBox {
            lastUseBoundingBox = useBoundingBox

            let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SparkSplatRenderShader")

            var vertexConstants = FunctionConstants()
            vertexConstants["use_sh"] = .bool(useSphericalHarmonics)
            vertexConstants["use_bounding_box"] = .bool(useBoundingBox)

            var fragmentConstants = FunctionConstants()
            fragmentConstants["convert_srgb_to_linear"] = .bool(convertSRGBToLinear)

            vertexShader = try shaderLibrary.function(named: "vertex_main", type: VertexShader.self, constants: vertexConstants)
            fragmentShader = try shaderLibrary.function(named: "fragment_main", type: FragmentShader.self, constants: fragmentConstants)
        }
        return (vertexShader, fragmentShader)
    }

    // MARK: - Render Pipeline

    private func renderPipeline(sortedIndices: SplatIndices, vertexShader: VertexShader, fragmentShader: FragmentShader) throws -> some Element {
        let viewMatrices = cameraMatrices.map(\.inverse)
        let cameraPositions = cameraMatrices.map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        let amplificationCount = cameraMatrices.count
        let device = _MTLCreateSystemDefaultDevice()

        // Build (or reuse) the per-cloud data buffer.
        let cloudDataBuffer: TypedMTLBuffer<SplatCloudData>
        if let cache = cloudDataCache, cache.modelMatrix == modelMatrix, cache.clouds == splatClouds {
            cloudDataBuffer = cache.buffer
        } else {
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
            cloudDataBuffer = try device.makeTypedBuffer(values: cloudDataArray, options: []).labeled("CloudData")
            cloudDataCache = CloudDataCache(modelMatrix: modelMatrix, clouds: splatClouds, buffer: cloudDataBuffer)
        }

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
            Draw { commandEncoder in
                let vertices: [SIMD2<Float>] = [
                    [-1, -1], [-1, 1], [1, -1], [1, 1]
                ]
                commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                if var viewMappings = amplificationViewMappings {
                    commandEncoder.setVertexAmplificationCount(amplificationCount, viewMappings: &viewMappings)
                } else {
                    commandEncoder.setVertexAmplificationCount(amplificationCount, viewMappings: nil)
                }
                if let indirectArgs = sortedIndices.indirectDrawArgs {
                    // GPU sort path: instanceCount is the cull survivor count
                    // written by the sort's block-scan kernel.
                    commandEncoder.drawPrimitives(type: .triangleStrip, indirectBuffer: indirectArgs, indirectBufferOffset: 0)
                } else {
                    commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: totalSplatCount)
                }
            }
            .parameter("indexedDistances", buffer: sortedIndices.indices.unsafeMTLBuffer)
            .parameter("viewMatrices", values: viewMatrices)
            .parameter("projectionMatrices", values: projectionMatrices)
            .parameter("drawableSize", value: drawableSize)
            .parameter("scale", value: Float(2.0))
            .parameter("cameraPositions", values: cameraPositions)
            // The cloud data array is bound directly (not nested inside
            // another argument buffer) because simulator Metal does not
            // support nested argument buffers.
            .parameter("cloudCount", functionType: .vertex, value: UInt32(splatClouds.count))
            .parameter("clouds", buffer: cloudDataBuffer.unsafeMTLBuffer)
            // SH degree for multi-cloud (shader looks up per-cloud SH buffers).
            // Reflection comes from the pipeline state, so this binds whenever
            // the PSO has use_sh baked in (even from a previous cloud) and is
            // skipped otherwise. Degree 0 short-circuits SH.
            .parameter("shDegree", functionType: .vertex, value: UInt32(useSphericalHarmonics ? maxSHDegree : 0))
            // Bounding box for vertex culling. When boundingBox is nil the
            // use_bounding_box function constant is false, the binding is absent
            // from reflection, and the placeholder value is silently skipped.
            .parameter("boundingBox", functionType: .vertex, value: boundingBox ?? BoundingBox3D())
        }
        .vertexDescriptor(vertexDescriptor)
        .renderPassDescriptorModifier { [amplificationCount] descriptor in
            // On visionOS layered layouts the render target array length is owned
            // by CompositorServices; forcing it to 1 breaks stereo rendering.
            #if !os(visionOS)
            if amplificationCount == 1 {
                descriptor.renderTargetArrayLength = 1
            }
            #else
            _ = amplificationCount
            #endif
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

// MARK: - Modifiers

public extension SparkSplatRenderPipeline {
    /// Sets vertex amplification view mappings for the draw.
    ///
    /// Use with a single camera/projection matrix to render one eye into a
    /// specific layer of a layered render target (per-eye rendering).
    func viewMappings(_ mappings: [MTLVertexAmplificationViewMapping]) -> Self {
        var copy = self
        copy.amplificationViewMappings = mappings
        return copy
    }
}

// MARK: - Buffer Release Modifier

#endif

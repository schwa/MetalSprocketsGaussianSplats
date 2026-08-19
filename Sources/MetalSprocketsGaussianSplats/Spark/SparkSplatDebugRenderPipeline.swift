#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import simd
import Splats

/// The debug visualization modes for Gaussian splat rendering.
public enum SplatDebugMode: String, CaseIterable, Sendable {
    /// Colors splats by distance from the cloud center.
    case distanceFromCenter
    /// Colors splats by size (maximum scale).
    case splatSize
    /// Colors splats by depth (distance from the camera).
    case depth
    /// Colors splats by opacity (alpha value).
    case opacity
    /// Colors splats by normal direction.
    case normal
    /// Colors splats by aspect ratio (elongation).
    case aspectRatio
    /// Colors splats by the cloud they belong to.
    case cloudIndex

    /// The display name for the user interface.
    public var displayName: String {
        switch self {
        case .distanceFromCenter:
            return "Distance from Center"
        case .splatSize:
            return "Splat Size"
        case .depth:
            return "Depth"
        case .opacity:
            return "Opacity"
        case .normal:
            return "Normal"
        case .aspectRatio:
            return "Aspect Ratio"
        case .cloudIndex:
            return "Cloud Index"
        }
    }

    /// A description of what the colors represent.
    public var colorDescription: String {
        switch self {
        case .distanceFromCenter:
            return "Blue = near center, Red = far from center"
        case .splatSize:
            return "Blue = small splats, Red = large splats"
        case .depth:
            return "Blue = close to camera, Red = far from camera"
        case .opacity:
            return "Blue = transparent, Red = opaque"
        case .normal:
            return "RGB = XYZ normal direction"
        case .aspectRatio:
            return "Blue = circular, Red = elongated"
        case .cloudIndex:
            return "Each cloud gets a unique color"
        }
    }
}

/// The parameters for the debug visualization modes.
public enum DebugParams: Sendable {
    case distance(DebugDistanceParams)
    case size(DebugSizeParams)
    case depth(DebugDepthParams)
    case opacity  // takes no parameters
    case normal   // takes no parameters
    case aspectRatio(DebugAspectRatioParams)
    case cloudIndex(DebugCloudIndexParams)
}

/// A variant of ``SparkSplatRenderPipeline`` that renders debug visualizations
/// such as depth, opacity, normals, aspect ratio, and cloud index.
///
/// Like ``SparkSplatRenderPipeline``, this pipeline does not manage sorting.
/// The caller supplies pre-sorted ``SplatIndices`` from an ``AsyncSortManager``.
/// See ``SparkSplatRenderPipeline`` for the full usage pattern.
public struct SparkSplatDebugRenderPipeline: Element {
    var splatClouds: [GPUSplatCloud<SparkSplat>]
    var projectionMatrices: [simd_float4x4]
    var modelMatrix: simd_float4x4
    var cameraMatrices: [simd_float4x4]
    var drawableSize: SIMD2<Float>
    var debugMode: SplatDebugMode
    var boundingBox: BoundingBox3D?
    var debugParams: DebugParams
    var sortedIndices: SplatIndices

    var vertexShader: VertexShader
    var fragmentShader: FragmentShader
    var vertexDescriptor: MTLVertexDescriptor

    /// The total splat count across all clouds.
    var totalSplatCount: Int {
        splatClouds.reduce(0) { $0 + $1.count }
    }

    // MARK: - Single Cloud Convenience Initializer

    /// Creates a pipeline for a single cloud with single-view rendering.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        drawableSize: SIMD2<Float>,
        debugParams: DebugParams,
        boundingBox: BoundingBox3D? = nil,
        sortedIndices: SplatIndices
    ) throws {
        try self.init(
            splatClouds: [splatCloud],
            projectionMatrices: [projectionMatrix],
            modelMatrix: modelMatrix,
            cameraMatrices: [cameraMatrix],
            drawableSize: drawableSize,
            debugParams: debugParams,
            boundingBox: boundingBox,
            sortedIndices: sortedIndices
        )
    }

    // MARK: - Multi-Cloud Initializer

    /// Creates a pipeline for multiple clouds with stereo (amplification) rendering.
    public init(
        splatClouds: [GPUSplatCloud<SparkSplat>],
        projectionMatrices: [simd_float4x4],
        modelMatrix: simd_float4x4,
        cameraMatrices: [simd_float4x4],
        drawableSize: SIMD2<Float>,
        debugParams: DebugParams,
        boundingBox: BoundingBox3D? = nil,
        sortedIndices: SplatIndices
    ) throws {
        precondition(projectionMatrices.count == cameraMatrices.count, "projectionMatrices and cameraMatrices must have the same count")
        precondition(!projectionMatrices.isEmpty, "Must have at least one projection matrix")
        precondition(!splatClouds.isEmpty, "Must have at least one splat cloud")

        self.splatClouds = splatClouds
        self.projectionMatrices = projectionMatrices
        self.modelMatrix = modelMatrix
        self.cameraMatrices = cameraMatrices
        self.drawableSize = drawableSize
        self.debugParams = debugParams
        self.boundingBox = boundingBox
        self.sortedIndices = sortedIndices

        switch debugParams {
        case .distance:
            self.debugMode = .distanceFromCenter
        case .size:
            self.debugMode = .splatSize
        case .depth:
            self.debugMode = .depth
        case .opacity:
            self.debugMode = .opacity
        case .normal:
            self.debugMode = .normal
        case .aspectRatio:
            self.debugMode = .aspectRatio
        case .cloudIndex:
            self.debugMode = .cloudIndex
        }

        // Same shader namespace as SparkSplatRenderPipeline.
        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SparkSplatRenderShader")

        var vertexConstants = FunctionConstants()
        vertexConstants["use_sh"] = .bool(false)  // debug mode uses no spherical harmonics
        vertexConstants["use_bounding_box"] = .bool(boundingBox != nil)

        // Same vertex shader as the normal render pipeline.
        self.vertexShader = try shaderLibrary.function(named: "vertex_main", type: VertexShader.self, constants: vertexConstants)

        let fragmentName: String
        switch debugMode {
        case .distanceFromCenter:
            fragmentName = "fragment_debug_distance"
        case .splatSize:
            fragmentName = "fragment_debug_size"
        case .depth:
            fragmentName = "fragment_debug_depth"
        case .opacity:
            fragmentName = "fragment_debug_opacity"
        case .normal:
            fragmentName = "fragment_debug_normal"
        case .aspectRatio:
            fragmentName = "fragment_debug_aspect_ratio"
        case .cloudIndex:
            fragmentName = "fragment_debug_cloud_index"
        }
        self.fragmentShader = try shaderLibrary.function(named: fragmentName, type: FragmentShader.self)

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        self.vertexDescriptor = vertexDescriptor
    }

    public var body: some Element {
        get throws {
            let viewMatrices = cameraMatrices.map(\.inverse)

            let cameraPositions = cameraMatrices.map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }

            let amplificationCount = cameraMatrices.count

            try Group {
                try renderPipeline(
                    indexedDistancesBuffer: sortedIndices.indices,
                    viewMatrices: viewMatrices,
                    cameraPositions: cameraPositions,
                    amplificationCount: amplificationCount
                )
            }
        }
    }

    // MARK: - Render Pipeline

    private func renderPipeline(
        indexedDistancesBuffer: TypedMTLBuffer<IndexedDistance>,
        viewMatrices: [simd_float4x4],
        cameraPositions: [SIMD3<Float>],
        amplificationCount: Int
    ) throws -> some Element {
        let device = MTLCreateSystemDefaultDevice()!

        var cloudDataArray: [SplatCloudData] = []
        for cloud in splatClouds {
            let combinedModel = modelMatrix * cloud.modelTransform
            let cloudData = SplatCloudData(
                splats: cloud.splats.unsafeMTLBuffer.gpuAddressAsUnsafeMutablePointer(type: SparkSplat.self),
                modelMatrix: combinedModel,
                shCoefficients: nil,  // debug mode uses no spherical harmonics
                opacity: cloud.opacity
            )
            cloudDataArray.append(cloudData)
        }

        let cloudDataBuffer = try device.makeTypedBuffer(values: cloudDataArray, options: []).labeled("CloudData")

        let argumentBuffer = MultiCloudArgumentBuffer(
            cloudCount: UInt32(splatClouds.count),
            clouds: cloudDataBuffer.unsafeMTLBuffer.gpuAddressAsUnsafeMutablePointer(type: SplatCloudData.self)
        )

        // Cloud buffers are referenced through GPU addresses, so they must be marked in use.
        var resourcesToUse: [MTLResource] = [cloudDataBuffer.unsafeMTLBuffer]
        for cloud in splatClouds {
            resourcesToUse.append(cloud.splats.unsafeMTLBuffer)
        }

        return try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
            let draw = Draw { commandEncoder in
                let vertices: [SIMD2<Float>] = [
                    [-1, -1], [-1, 1], [1, -1], [1, 1]
                ]
                commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
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
            // Bounding box for vertex culling. If boundingBox is nil, the
            // use_bounding_box function constant is false, reflection omits the
            // binding, and the placeholder value is skipped.
            .parameter("boundingBox", functionType: .vertex, value: boundingBox ?? BoundingBox3D())

            // Fragment shader parameters for the debug mode. The opacity and
            // normal shaders take no parameters.
            switch debugParams {
            case .distance(let params):
                draw.parameter("params", functionType: .fragment, value: params)
            case .size(let params):
                draw.parameter("params", functionType: .fragment, value: params)
            case .depth(let params):
                draw.parameter("params", functionType: .fragment, value: params)
            case .opacity, .normal:
                draw
            case .aspectRatio(let params):
                draw.parameter("params", functionType: .fragment, value: params)
            case .cloudIndex(let params):
                draw.parameter("params", functionType: .fragment, value: params)
            }
        }
        .vertexDescriptor(vertexDescriptor)
        .renderPassDescriptorModifier { descriptor in
            descriptor.renderTargetArrayLength = 1
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

#endif

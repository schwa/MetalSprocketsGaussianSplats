#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSupport
import simd
import Splats

/// Debug visualization modes for Gaussian splat rendering
public enum SplatDebugMode: String, CaseIterable, Sendable {
    /// Colorize splats by distance from cloud center
    case distanceFromCenter
    /// Colorize splats by their size (max scale)
    case splatSize
    /// Colorize splats by depth (distance from camera)
    case depth
    /// Colorize splats by their opacity/alpha value
    case opacity
    /// Colorize splats by their normal direction
    case normal
    /// Colorize splats by their aspect ratio (elongation)
    case aspectRatio
    /// Colorize splats by which cloud they belong to
    case cloudIndex

    /// Human-readable display name for UI
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

    /// Description of what the colors represent
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

/// A debug render pipeline for Gaussian splats that uses the Spark vertex shader
/// with alternative fragment shaders for visualization/debugging purposes.
///
/// Like ``SparkSplatRenderPipeline``, this pipeline does not manage sorting.
/// The caller provides pre-sorted ``SplatIndices`` from an ``AsyncSortManager``.
/// See ``SparkSplatRenderPipeline`` for the full usage pattern.
///
/// Parameters for debug visualization modes
public enum DebugParams: Sendable {
    case distance(DebugDistanceParams)
    case size(DebugSizeParams)
    case depth(DebugDepthParams)
    case opacity  // No params needed
    case normal   // No params needed
    case aspectRatio(DebugAspectRatioParams)
    case cloudIndex(DebugCloudIndexParams)
}

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

    /// Total splat count across all clouds
    var totalSplatCount: Int {
        splatClouds.reduce(0) { $0 + $1.count }
    }

    // MARK: - Single Cloud Convenience Initializer

    /// Convenience initializer for single cloud, single-view rendering
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

    /// Full initializer supporting multiple clouds and stereo/amplification rendering
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

        // Derive debug mode from params
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

        // Load shaders from the same namespace as SparkSplatRenderPipeline
        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SparkSplatRenderShader")

        var vertexConstants = FunctionConstants()
        vertexConstants["use_sh"] = .bool(false)  // No SH for debug mode
        vertexConstants["use_bounding_box"] = .bool(boundingBox != nil)

        // Reuse the same vertex shader as the normal render pipeline
        self.vertexShader = try shaderLibrary.function(named: "vertex_main", type: VertexShader.self, constants: vertexConstants)

        // Select debug fragment shader based on mode
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

        // Build per-cloud data array
        var cloudDataArray: [SplatCloudData] = []
        for cloud in splatClouds {
            let combinedModel = modelMatrix * cloud.modelTransform
            let cloudData = SplatCloudData(
                splats: cloud.splats.unsafeMTLBuffer.gpuAddressAsUnsafeMutablePointer(type: SparkSplat.self),
                modelMatrix: combinedModel,
                shCoefficients: nil,  // No SH for debug mode
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

        // Collect all resources that need to be marked as in use
        var resourcesToUse: [MTLResource] = [cloudDataBuffer.unsafeMTLBuffer]
        for cloud in splatClouds {
            resourcesToUse.append(cloud.splats.unsafeMTLBuffer)
        }

        return try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
            Draw { [boundingBox, debugParams] commandEncoder in
                let vertices: [SIMD2<Float>] = [
                    [-1, -1], [-1, 1], [1, -1], [1, 1]
                ]
                commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)

                // Set bounding box for vertex culling
                if var bbox = boundingBox {
                    commandEncoder.setVertexBytes(&bbox, length: MemoryLayout<BoundingBox3D>.size, index: 12)
                }

                // Set fragment shader parameters based on debug mode
                switch debugParams {
                case .distance(var params):
                    commandEncoder.setFragmentBytes(&params, length: MemoryLayout<DebugDistanceParams>.size, index: 0)
                case .size(var params):
                    commandEncoder.setFragmentBytes(&params, length: MemoryLayout<DebugSizeParams>.size, index: 0)
                case .depth(var params):
                    commandEncoder.setFragmentBytes(&params, length: MemoryLayout<DebugDepthParams>.size, index: 0)
                case .opacity, .normal:
                    // No parameters needed
                    break
                case .aspectRatio(var params):
                    commandEncoder.setFragmentBytes(&params, length: MemoryLayout<DebugAspectRatioParams>.size, index: 0)
                case .cloudIndex(var params):
                    commandEncoder.setFragmentBytes(&params, length: MemoryLayout<DebugCloudIndexParams>.size, index: 0)
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

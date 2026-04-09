#if !arch(x86_64)
import Foundation
import Metal
import MetalKit
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

/// A stochastic splat renderer that uses random sampling for transparency.
///
/// - Important: This renderer is **experimental** and may have significant changes
///   or be removed in future versions. Use ``SparkSplatRenderPipeline`` for production.
///
/// This renderer uses stochastic (random) sampling to approximate alpha blending,
/// which can produce noisy results but doesn't require depth sorting.
public struct StochasticSplatRenderPipeline: Element {
    var splatCloud: GPUSplatCloud<SparkSplat>
    var projectionMatrices: [simd_float4x4]
    var modelMatrix: simd_float4x4
    var cameraMatrices: [simd_float4x4]
    var drawableSize: SIMD2<Float>
    var frameTime: UInt32
    var alphaThreshold: Float
    var useSphericalHarmonics: Bool

    // Noise method
    var useBlueNoise: Bool

    @MSState
    var blueNoiseTexture: MTLTexture
    @MSState
    var vertexShader: VertexShader
    @MSState
    var fragmentShader: FragmentShader
    var vertexDescriptor: MTLVertexDescriptor

    /// - Parameter useSphericalHarmonics: Override SH usage. If nil, automatically enables SH when data is available.
    /// Convenience initializer for single-view (mono) rendering.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        drawableSize: SIMD2<Float>,
        frameTime: UInt32,
        alphaThreshold: Float = 0.95,
        convertSRGBToLinear: Bool = true,
        useBlueNoise: Bool = true,
        useSphericalHarmonics: Bool? = nil
    ) throws {
        try self.init(
            splatCloud: splatCloud,
            projectionMatrices: [projectionMatrix],
            modelMatrix: modelMatrix,
            cameraMatrices: [cameraMatrix],
            drawableSize: drawableSize,
            frameTime: frameTime,
            alphaThreshold: alphaThreshold,
            convertSRGBToLinear: convertSRGBToLinear,
            useBlueNoise: useBlueNoise,
            useSphericalHarmonics: useSphericalHarmonics
        )
    }

    /// Full initializer supporting stereo/amplification rendering.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrices: [simd_float4x4],
        modelMatrix: simd_float4x4,
        cameraMatrices: [simd_float4x4],
        drawableSize: SIMD2<Float>,
        frameTime: UInt32,
        alphaThreshold: Float = 0.95,
        convertSRGBToLinear: Bool = true,
        useBlueNoise: Bool = true,
        useSphericalHarmonics: Bool? = nil
    ) throws {
        precondition(projectionMatrices.count == cameraMatrices.count)
        precondition(!projectionMatrices.isEmpty)
        self.splatCloud = splatCloud
        self.projectionMatrices = projectionMatrices
        self.modelMatrix = modelMatrix
        self.cameraMatrices = cameraMatrices
        self.drawableSize = drawableSize
        self.frameTime = frameTime
        self.alphaThreshold = alphaThreshold
        self.useBlueNoise = useBlueNoise

        // Determine if SH should be used: explicit override, or auto-detect from data
        let hasSHData = splatCloud.shCoefficients != nil
        let useSH = useSphericalHarmonics ?? hasSHData
        let effectiveUseSH = useSH && hasSHData // Can only use SH if data exists
        self.useSphericalHarmonics = effectiveUseSH

        // Load blue noise texture
        guard let url = Bundle.module.url(forResource: "LDR_RGBA_0", withExtension: "png") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let device = _MTLCreateSystemDefaultDevice()
        let textureLoader = MTKTextureLoader(device: device)
        self.blueNoiseTexture = try textureLoader.newTexture(URL: url, options: [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue
        ])

        // Load Stochastic shaders
        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("StochasticSplatRenderShader")

        var vertexConstants = FunctionConstants()
        vertexConstants["use_sh"] = .bool(effectiveUseSH)

        var fragmentConstants = FunctionConstants()
        fragmentConstants["convert_srgb_to_linear"] = .bool(convertSRGBToLinear)
        fragmentConstants["use_blue_noise"] = .bool(useBlueNoise)

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
            let shBuffer = useSphericalHarmonics ? splatCloud.shCoefficients : nil
            let degree = useSphericalHarmonics ? splatCloud.shDegree : 0
            var time = frameTime
            var threshold = alphaThreshold
            let viewMatrices = cameraMatrices.map(\.inverse)
            let cameraPositions = cameraMatrices.map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
            let amplificationCount = cameraMatrices.count
            try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
                Draw { commandEncoder in
                    let vertices: [SIMD2<Float>] = [
                        [-1, -1], [-1, 1], [1, -1], [1, 1]
                    ]
                    commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                    commandEncoder.setVertexAmplificationCount(amplificationCount, viewMappings: nil)
                    // Set time uniform for fragment shader hash
                    commandEncoder.setFragmentBytes(&time, length: MemoryLayout<UInt32>.size, index: 0)
                    // Set alpha threshold for fragment shader
                    commandEncoder.setFragmentBytes(&threshold, length: MemoryLayout<Float>.size, index: 1)
                    // Set blue noise texture
                    commandEncoder.setFragmentTexture(blueNoiseTexture, index: 0)
                    // Set SH buffer and degree if available
                    if let buffer = shBuffer {
                        var shDegreeValue = UInt32(degree)
                        commandEncoder.setVertexBytes(&shDegreeValue, length: MemoryLayout<UInt32>.size, index: 11)
                        commandEncoder.setVertexBuffer(buffer.unsafeMTLBuffer, offset: 0, index: 12)
                    }
                    commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splatCloud.count)
                }
                .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
                .parameter("modelMatrix", value: modelMatrix)
                .parameter("viewMatrices", values: viewMatrices)
                .parameter("projectionMatrices", values: projectionMatrices)
                .parameter("drawableSize", value: drawableSize)
                .parameter("scale", value: Float(2.0))
                .parameter("cameraPositions", values: cameraPositions)
            }
            .vertexDescriptor(vertexDescriptor)
            .depthCompare(function: .less, enabled: true)
            .renderPipelineDescriptorModifier { [amplificationCount] descriptor in
                descriptor.inputPrimitiveTopology = .triangle
                descriptor.maxVertexAmplificationCount = amplificationCount
            }
        }
    }
}

#endif

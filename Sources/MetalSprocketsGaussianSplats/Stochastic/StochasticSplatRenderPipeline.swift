#if !arch(x86_64)
import Foundation
import Metal
import MetalKit
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSupport

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

    var useBlueNoise: Bool

    @MSState
    var blueNoiseTexture: MTLTexture
    @MSState
    var vertexShader: VertexShader
    @MSState
    var fragmentShader: FragmentShader
    var vertexDescriptor: MTLVertexDescriptor

    /// Convenience initializer for single-view (mono) rendering.
    ///
    /// - Parameters:
    ///   - splatCloud: The splat cloud to render.
    ///   - projectionMatrix: The camera projection matrix.
    ///   - modelMatrix: The scene-level model transform.
    ///   - cameraMatrix: The camera (view-to-world) matrix.
    ///   - drawableSize: The render target size in pixels.
    ///   - frameTime: A per-frame counter used to vary the stochastic noise pattern.
    ///   - alphaThreshold: Opacity above which a splat fragment is treated as fully opaque.
    ///   - convertSRGBToLinear: Whether splat colors are converted from sRGB to linear in the shader.
    ///   - useBlueNoise: Uses a blue-noise texture for sampling instead of white noise, reducing visible grain.
    ///   - useSphericalHarmonics: Override SH usage. If nil, automatically enables SH when data is available.
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
    ///
    /// - Parameters:
    ///   - splatCloud: The splat cloud to render.
    ///   - projectionMatrices: One projection matrix per view (two for stereo).
    ///   - modelMatrix: The scene-level model transform.
    ///   - cameraMatrices: One camera (view-to-world) matrix per view, matching `projectionMatrices`.
    ///   - drawableSize: The render target size in pixels.
    ///   - frameTime: A per-frame counter used to vary the stochastic noise pattern.
    ///   - alphaThreshold: Opacity above which a splat fragment is treated as fully opaque.
    ///   - convertSRGBToLinear: Whether splat colors are converted from sRGB to linear in the shader.
    ///   - useBlueNoise: Uses a blue-noise texture for sampling instead of white noise, reducing visible grain.
    ///   - useSphericalHarmonics: Override SH usage. If nil, automatically enables SH when data is available.
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

        // SH: explicit override, else auto-detect from data.
        let hasSHData = splatCloud.shCoefficients != nil
        let useSH = useSphericalHarmonics ?? hasSHData
        let effectiveUseSH = useSH && hasSHData // Can only use SH if data exists
        self.useSphericalHarmonics = effectiveUseSH

        guard let url = Bundle.module.url(forResource: "LDR_RGBA_0", withExtension: "png") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let device = _MTLCreateSystemDefaultDevice()
        let textureLoader = MTKTextureLoader(device: device)
        self.blueNoiseTexture = try textureLoader.newTexture(URL: url, options: [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue
        ])

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("StochasticSplatRenderShader")

        var vertexConstants = FunctionConstants()
        vertexConstants["use_sh"] = .bool(effectiveUseSH)

        var fragmentConstants = FunctionConstants()
        fragmentConstants["convert_srgb_to_linear"] = .bool(convertSRGBToLinear)
        fragmentConstants["use_blue_noise"] = .bool(useBlueNoise)

        self.vertexShader = try shaderLibrary.function(named: "vertex_main", type: VertexShader.self, constants: vertexConstants)
        self.fragmentShader = try shaderLibrary.function(named: "fragment_main", type: FragmentShader.self, constants: fragmentConstants)

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
            let viewMatrices = cameraMatrices.map(\.inverse)
            let cameraPositions = cameraMatrices.map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
            let amplificationCount = cameraMatrices.count
            try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
                let draw = Draw { commandEncoder in
                    let vertices: [SIMD2<Float>] = [
                        [-1, -1], [-1, 1], [1, -1], [1, 1]
                    ]
                    commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                    commandEncoder.setVertexAmplificationCount(amplificationCount, viewMappings: nil)
                    commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splatCloud.count)
                }
                .parameter("uTime", value: frameTime)
                .parameter("alphaThreshold", value: alphaThreshold)
                .parameter("blueNoiseTexture", texture: blueNoiseTexture)
                .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
                .parameter("modelMatrix", value: modelMatrix)
                .parameter("viewMatrices", values: viewMatrices)
                .parameter("projectionMatrices", values: projectionMatrices)
                .parameter("drawableSize", value: drawableSize)
                .parameter("scale", value: Float(2.0))
                .parameter("cameraPositions", values: cameraPositions)
                if let shBuffer {
                    draw
                        .parameter("shDegree", value: UInt32(degree))
                        .parameter("shCoefficients", buffer: shBuffer.unsafeMTLBuffer)
                } else {
                    draw
                }
            }
            .vertexDescriptor(vertexDescriptor)
            .renderPipelineDescriptorModifier { [amplificationCount] descriptor in
                descriptor.inputPrimitiveTopology = .triangle
                descriptor.maxVertexAmplificationCount = amplificationCount
            }
        }
    }
}

#endif

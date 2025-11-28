#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import Metal
import MetalKit
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI
internal import os
import SwiftUI

private let stochasticLogger: Logger? = Logger(subsystem: "stochastic-splats", category: "stochastic-splats")

public struct StochasticSplatView: View {
    private var splatCloud: SplatCloud<SparkSplat>
    private var projection: any ProjectionProtocol
    private var cameraMatrix: simd_float4x4
    private var modelMatrix: simd_float4x4

    // Textures for temporal accumulation
    @State private var renderTexture: MTLTexture?
    @State private var depthTexture: MTLTexture?
    @State private var accumulationTextureA: MTLTexture?
    @State private var accumulationTextureB: MTLTexture?

    // Camera tracking for blend factor
    @State private var previousCameraMatrix: simd_float4x4?

    // Blend factor controls
    @State private var stationaryBlend: Float = 0.1
    @State private var movingBlend: Float = 0.5
    @State private var enableAccumulation: Bool = true
    @State private var alphaThreshold: Float = 0.95
    @State private var useBlueNoise: Bool = true

    // Compute shader for blending
    private var blendFunction: ComputeKernel

    // Blit shaders for display
    private var blitVertexShader: VertexShader
    private var blitFragmentShader: FragmentShader

    // Blue noise texture
    private var blueNoiseTexture: MTLTexture

    public init(
        splatCloud: SplatCloud<SparkSplat>,
        projection: any ProjectionProtocol,
        cameraMatrix: simd_float4x4,
        modelMatrix: simd_float4x4 = .identity
    ) throws {
        self.splatCloud = splatCloud
        self.projection = projection
        self.cameraMatrix = cameraMatrix
        self.modelMatrix = modelMatrix

        // Load shaders
        let library = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
        let accumLibrary = library.namespaced("TemporalAccumulationShader")
        self.blendFunction = try accumLibrary.function(named: "blend", type: ComputeKernel.self)
        let blitLibrary = library.namespaced("BlitShader")
        self.blitVertexShader = try blitLibrary.function(named: "vertex_main", type: VertexShader.self)
        self.blitFragmentShader = try blitLibrary.function(named: "fragment_main", type: FragmentShader.self)

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
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let time = UInt32(truncatingIfNeeded: Int(timeline.date.timeIntervalSince1970 * 60))
            renderView(time: time)
        }
        .onAppear {
            previousCameraMatrix = cameraMatrix
        }
        .onChange(of: cameraMatrix) { oldValue, _ in
            previousCameraMatrix = oldValue
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Temporal Accumulation", isOn: $enableAccumulation)
                    .font(.headline)

                if enableAccumulation {
                    HStack {
                        Text("Stationary:")
                        Slider(value: $stationaryBlend, in: 0.01...0.5)
                        Text("\(stationaryBlend, format: .number.precision(.fractionLength(2)))")
                            .frame(width: 40)
                    }

                    HStack {
                        Text("Moving:")
                        Slider(value: $movingBlend, in: 0.1...1.0)
                        Text("\(movingBlend, format: .number.precision(.fractionLength(2)))")
                            .frame(width: 40)
                    }
                }

                Divider()

                HStack {
                    Text("Alpha Threshold:")
                    Slider(value: $alphaThreshold, in: 0.5...1.0)
                    Text("\(alphaThreshold, format: .number.precision(.fractionLength(2)))")
                        .frame(width: 40)
                }

                Divider()

                Toggle("Blue Noise", isOn: $useBlueNoise)
            }
            .padding()
            .frame(maxWidth: 250)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()
        }
    }

    @ViewBuilder
    private func renderView(time: UInt32) -> some View {
        RenderView { _, drawableSize in
            if enableAccumulation, let renderTexture, let depthTexture, let accumulationTextureA, let accumulationTextureB {
                // Ping-pong between buffers based on frame
                let useTextureA = (time % 2) == 0
                let currentAccum = useTextureA ? accumulationTextureA : accumulationTextureB
                let outputAccum = useTextureA ? accumulationTextureB : accumulationTextureA

                // Calculate blend factor based on camera movement
                let blendFactor = calculateBlendFactor()

                // 1. Render splats to intermediate texture
                try RenderPass(label: "Stochastic Splat Pass") {
                    let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                    try StochasticSplatRenderPipeline(
                        splatCloud: splatCloud,
                        projectionMatrix: projectionMatrix,
                        modelMatrix: modelMatrix,
                        cameraMatrix: cameraMatrix,
                        drawableSize: SIMD2<Float>(drawableSize),
                        frameTime: time,
                        alphaThreshold: alphaThreshold,
                        blueNoiseTexture: blueNoiseTexture,
                        shCoefficients: nil,
                        shDegree: 0,
                        useBlueNoise: useBlueNoise
                    )
                }
                .renderPassDescriptorModifier { descriptor in
                    descriptor.colorAttachments[0].texture = renderTexture
                    descriptor.colorAttachments[0].loadAction = .clear
                    descriptor.colorAttachments[0].storeAction = .store
                    descriptor.depthAttachment.texture = depthTexture
                    descriptor.depthAttachment.loadAction = .clear
                    descriptor.depthAttachment.storeAction = .dontCare
                }

                // 2. Blend with accumulation buffer
                try ComputePass(label: "Temporal Accumulation Pass") {
                    try ComputePipeline(computeKernel: blendFunction) {
                        try ComputeDispatch(
                            threadsPerGrid: MTLSize(width: renderTexture.width, height: renderTexture.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
                        )
                        .parameter("currentFrame", texture: renderTexture)
                        .parameter("accumulationTexture", texture: currentAccum)
                        .parameter("outputTexture", texture: outputAccum)
                        .parameter("blendFactor", value: blendFactor)
                    }
                }

                // 3. Display accumulated result
                try RenderPass(label: "Display Pass") {
                    try RenderPipeline(vertexShader: blitVertexShader, fragmentShader: blitFragmentShader) {
                        Draw { encoder in
                            encoder.setFragmentTexture(outputAccum, index: 0)
                            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        }
                    }
                }
            } else {
                // Render directly without accumulation
                try RenderPass {
                    let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                    try StochasticSplatRenderPipeline(
                        splatCloud: splatCloud,
                        projectionMatrix: projectionMatrix,
                        modelMatrix: modelMatrix,
                        cameraMatrix: cameraMatrix,
                        drawableSize: SIMD2<Float>(drawableSize),
                        frameTime: time,
                        alphaThreshold: alphaThreshold,
                        blueNoiseTexture: blueNoiseTexture,
                        shCoefficients: nil,
                        shDegree: 0,
                        useBlueNoise: useBlueNoise
                    )
                }
            }
        }
        .onDrawableSizeChange { size in
            ensureTextures(size: size)
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .metalDepthStencilPixelFormat(.depth32Float)
    }

    private func calculateBlendFactor() -> Float {
        guard let previous = previousCameraMatrix else {
            return 1.0  // First frame - use full new image
        }

        // Calculate camera movement
        let currentPos = SIMD3<Float>(cameraMatrix.columns.3.x, cameraMatrix.columns.3.y, cameraMatrix.columns.3.z)
        let previousPos = SIMD3<Float>(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
        let positionDelta = simd_length(currentPos - previousPos)

        // Also check rotation change (simplified - just compare matrix elements)
        let rotationDelta = abs(cameraMatrix[0][0] - previous[0][0]) +
            abs(cameraMatrix[1][1] - previous[1][1]) +
            abs(cameraMatrix[2][2] - previous[2][2])

        let totalDelta = positionDelta + rotationDelta * 0.5

        // Interpolate between stationary and moving blend based on movement
        if totalDelta > 0.01 {
            // Clamp and interpolate for smooth transition
            let t = min(1.0, totalDelta / 0.1)
            return stationaryBlend + t * (movingBlend - stationaryBlend)
        }
        return stationaryBlend
    }

    private func ensureTextures(size: CGSize) {
        let width = Int(size.width)
        let height = Int(size.height)
        // Check if textures exist and are the right size
        if let existing = renderTexture, existing.width == width, existing.height == height {
            return
        }
        createTextures(size: size)
    }

    private func createTextures(size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            return
        }

        let device = _MTLCreateSystemDefaultDevice()
        let width = Int(size.width)
        let height = Int(size.height)

        // Render target
        let renderDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        renderDescriptor.usage = [.renderTarget, .shaderRead]
        renderTexture = device.makeTexture(descriptor: renderDescriptor)
        renderTexture?.label = "Stochastic Render Texture"

        // Depth texture
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthTexture = device.makeTexture(descriptor: depthDescriptor)
        depthTexture?.label = "Stochastic Depth Texture"

        // Accumulation buffers (ping-pong)
        let accumDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        accumDescriptor.usage = [.shaderRead, .shaderWrite]
        accumulationTextureA = device.makeTexture(descriptor: accumDescriptor)
        accumulationTextureA?.label = "Accumulation Texture A"
        accumulationTextureB = device.makeTexture(descriptor: accumDescriptor)
        accumulationTextureB?.label = "Accumulation Texture B"

        // Reset accumulation state
        previousCameraMatrix = nil
    }
}
#endif

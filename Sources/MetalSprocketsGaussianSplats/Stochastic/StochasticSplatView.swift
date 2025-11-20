#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
internal import os
import Metal
import SwiftUI
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI

private let stochasticLogger: Logger? = Logger(subsystem: "stochastic-splats", category: "stochastic-splats")

public struct StochasticSplatView<Splat: SortableSplatProtocol>: View {
    private var splatCloud: SplatCloud<Splat>
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

    // Compute shader for blending
    @State private var blendFunction: ComputeKernel?

    // Blit shaders for display
    @State private var blitVertexShader: VertexShader?
    @State private var blitFragmentShader: FragmentShader?

    public init(
        splatCloud: SplatCloud<Splat>,
        projection: any ProjectionProtocol,
        cameraMatrix: simd_float4x4,
        modelMatrix: simd_float4x4 = .identity
    ) {
        self.splatCloud = splatCloud
        self.projection = projection
        self.cameraMatrix = cameraMatrix
        self.modelMatrix = modelMatrix
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let time = UInt32(truncatingIfNeeded: Int(timeline.date.timeIntervalSince1970 * 60))
            renderView(time: time)
        }
        .onAppear {
            loadBlendShader()
            previousCameraMatrix = cameraMatrix
        }
        .onChange(of: cameraMatrix) { oldValue, _ in
            previousCameraMatrix = oldValue
        }
    }

    private func loadBlendShader() {
        do {
            let library = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders())

            let accumLibrary = library.namespaced("TemporalAccumulationShader")
            blendFunction = try accumLibrary.function(named: "blend", type: ComputeKernel.self)

            let blitLibrary = library.namespaced("BlitShader")
            blitVertexShader = try blitLibrary.function(named: "vertex_main", type: VertexShader.self)
            blitFragmentShader = try blitLibrary.function(named: "fragment_main", type: FragmentShader.self)
        } catch {
            stochasticLogger?.error("Failed to load shaders: \(error)")
        }
    }

    @ViewBuilder
    private func renderView(time: UInt32) -> some View {
        RenderView { _, drawableSize in
            if let renderTexture, let depthTexture, let accumulationTextureA, let accumulationTextureB, let blendFunction, let blitVertexShader, let blitFragmentShader {
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
                        shCoefficients: nil,
                        shDegree: 0
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
            }
        }
        .onDrawableSizeChange { size in
            createTextures(size: size)
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

        // Soft reset: higher blend factor when camera moves
        if totalDelta > 0.1 {
            return 0.8  // Fast blend for significant movement
        } else if totalDelta > 0.01 {
            return 0.3  // Medium blend for small movement
        } else {
            return 0.1  // Slow accumulation when stationary
        }
    }

    private func createTextures(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

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

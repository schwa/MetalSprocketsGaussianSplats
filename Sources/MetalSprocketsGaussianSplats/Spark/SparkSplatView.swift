#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI
import SwiftUI

public struct SparkSplatView: View {
    private var splatCloud: SplatCloud<SparkSplat>
    private var projection: any ProjectionProtocol
    private var cameraMatrix: simd_float4x4
    private var modelMatrix: simd_float4x4
    private var shCoefficients: TypedMTLBuffer<Float>?
    private var shDegree: UInt8
    private var onFrameCompleted: (@Sendable () -> Void)?

    @State private var enableSH: Bool

    public init(
        splatCloud: SplatCloud<SparkSplat>,
        projection: any ProjectionProtocol,
        cameraMatrix: simd_float4x4,
        modelMatrix: simd_float4x4 = .identity,
        shCoefficients: TypedMTLBuffer<Float>? = nil,
        shDegree: UInt8 = 0,
        onFrameCompleted: (@Sendable () -> Void)? = nil
    ) {
        self.splatCloud = splatCloud
        self.projection = projection
        self.cameraMatrix = cameraMatrix
        self.modelMatrix = modelMatrix
        self.shCoefficients = shCoefficients
        self.shDegree = shDegree
        self.onFrameCompleted = onFrameCompleted
        // Default to OFF (colors are loaded with 0.282 scale for correct display)
        self._enableSH = State(initialValue: false)
    }

    public var body: some View {
        RenderView { _, drawableSize in
            try RenderPass {
                let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                try SparkSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: SIMD2<Float>(drawableSize),
                    // Always pass buffer to keep function constant stable, toggle via shDegree
                    shCoefficients: shCoefficients,
                    shDegree: enableSH ? shDegree : 0
                )
            }
            .onCommandBufferCompleted { _ in
                onFrameCompleted?()
            }
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .overlay(alignment: .topLeading) {
            if shCoefficients != nil {
                VStack(alignment: .leading) {
                    Toggle("Spherical Harmonics", isOn: $enableSH)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .leading) {
                Text("SH Info")
                    .font(.headline)
                if let shCoefficients {
                    Text("Degree: \(shDegree)")
                    Text("Buffer count: \(shCoefficients.count)")
                    Text("Enabled: \(enableSH ? "Yes" : "No")")
                    // Show first few values to verify data
                    if !shCoefficients.isEmpty {
                        let ptr = shCoefficients.unsafeMTLBuffer.contents().assumingMemoryBound(to: Float.self)
                        let sample = (0..<min(3, shCoefficients.count)).map { ptr[$0] }
                        Text("Sample: \(sample.map { String(format: "%.3f", $0) }.joined(separator: ", "))")
                    }
                } else {
                    Text("No SH data")
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()
        }
    }
}
#endif

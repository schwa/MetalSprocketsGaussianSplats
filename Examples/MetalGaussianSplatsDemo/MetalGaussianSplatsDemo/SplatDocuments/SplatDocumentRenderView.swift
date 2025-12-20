import GeometryLite3D
import Interaction3D
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import simd
import SwiftUI
import UniformTypeIdentifiers

struct SplatDocumentRenderView: View {
    let rendererType: SplatRendererType
    let descriptor: SplatCloudDescriptor

    @State private var cameraMatrix: simd_float4x4 = .identity
    @State private var modelMatrix: simd_float4x4 = .identity
    @State private var projection: (any ProjectionProtocol) = PerspectiveProjection(verticalAngleOfView: .degrees(90), depthMode: .standard(zClip: 0.01 ... 1_000))

    var body: some View {
        WorldView(projection: $projection, cameraMatrix: $cameraMatrix) {
            RenderView { context, drawableSize in
                SplatRenderPass(rendererType: rendererType, descriptor: descriptor, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix, drawableSize: drawableSize, frame: context.frameUniforms.index)
            }
            .metalColorPixelFormat(.bgra8Unorm_srgb)
            .metalClearColor(.init(red: 0, green: 0, blue: 0, alpha: 1))
        }
    }
}

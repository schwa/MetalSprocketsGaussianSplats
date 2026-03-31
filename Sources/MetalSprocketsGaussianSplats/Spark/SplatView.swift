#if !arch(x86_64)
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import simd
import Splats
import SwiftUI

/// A SwiftUI view that renders a Gaussian splat cloud using the Spark renderer.
///
/// `SplatView` encapsulates the full `AsyncSortManager` lifecycle so callers do not need
/// to manage sorting manually. It owns the sort manager, subscribes to sorted indices,
/// requests sorts when the camera or model matrix changes, and renders nothing until the
/// first sort completes.
///
/// ## Basic Usage
///
/// ```swift
/// struct MyView: View {
///     let device = MTLCreateSystemDefaultDevice()!
///     let splatCloud: GPUSplatCloud<SparkSplat>
///
///     @State private var cameraMatrix = simd_float4x4(translation: [0, 0, 3])
///
///     var body: some View {
///         SplatView(
///             splatCloud: splatCloud,
///             cameraMatrix: cameraMatrix,
///             modelMatrix: .identity,
///             projection: PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01...1_000))
///         )
///         .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())
///     }
/// }
/// ```
public struct SplatView: View {
    private let splatCloud: GPUSplatCloud<SparkSplat>
    private let cameraMatrix: simd_float4x4
    private let modelMatrix: simd_float4x4
    private let projection: PerspectiveProjection

    @State private var sortedIndices: SplatIndices?
    @State private var sortManager: AsyncSortManager<SparkSplat>

    /// Creates a `SplatView` that renders the given splat cloud.
    ///
    /// - Parameters:
    ///   - splatCloud: The GPU splat cloud to render.
    ///   - cameraMatrix: The camera-to-world transform matrix.
    ///   - modelMatrix: The model-to-world transform matrix.
    ///   - projection: The perspective projection to use for rendering.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        cameraMatrix: simd_float4x4,
        modelMatrix: simd_float4x4 = .identity,
        projection: PerspectiveProjection = PerspectiveProjection(
            verticalAngleOfView: .degrees(60),
            depthMode: .standard(zClip: 0.01 ... 1_000)
        )
    ) {
        self.splatCloud = splatCloud
        self.cameraMatrix = cameraMatrix
        self.modelMatrix = modelMatrix
        self.projection = projection
        let device = MTLCreateSystemDefaultDevice()!
        _sortManager = State(initialValue: try! AsyncSortManager<SparkSplat>(
            device: device,
            splatCloud: splatCloud,
            capacity: splatCloud.count
        ))
    }

    public var body: some View {
        RenderView { _, drawableSize in
            let projectionMatrix = projection.projectionMatrix(for: drawableSize)
            if let sortedIndices {
                try RenderPass {
                    try SparkSplatRenderPipeline(
                        splatCloud: splatCloud,
                        projectionMatrix: projectionMatrix,
                        modelMatrix: modelMatrix,
                        cameraMatrix: cameraMatrix,
                        drawableSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
                        sortedIndices: sortedIndices
                    )
                }
                .renderPassDescriptorModifier { descriptor in
                    descriptor.renderTargetArrayLength = 1
                }
            }
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .task {
            sortManager.requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
            for await indices in sortManager.sortedIndicesStream {
                if let old = sortedIndices {
                    sortManager.release(old)
                }
                sortedIndices = indices
            }
        }
        .onChange(of: splatCloud, initial: false) { _, newCloud in
            Task {
                await sortManager.setSplatCloud(newCloud)
                sortManager.requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
            }
        }
        .onChange(of: cameraMatrix) {
            sortManager.requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
        }
        .onChange(of: modelMatrix) {
            sortManager.requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
        }
    }
}

#endif

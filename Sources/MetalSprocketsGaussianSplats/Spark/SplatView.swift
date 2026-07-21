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
///
/// ## Known Issues
///
/// On macOS, applying `.toolbar` or wrapping the view in a `NavigationStack`
/// can leave the underlying `MTKView` with a zero initial size, so nothing
/// renders until the window is resized. This is a MetalSprockets `RenderView`
/// bug (MetalSprockets#311). Until it is fixed upstream, place UI controls in
/// an `.overlay` instead of a toolbar, as the demo app does.
public struct SplatView: View {
    private let splatCloud: GPUSplatCloud<SparkSplat>
    private let cameraMatrix: simd_float4x4
    private let modelMatrix: simd_float4x4
    private let projection: PerspectiveProjection

    @Environment(\.splatRenderer) private var renderer
    @Environment(\.displayScale) private var displayScale

    @State private var sortedIndices: SplatIndices?
    @State private var sortManager: AsyncSortManager<SparkSplat>
    @State private var pointSplatStatistics = PointSplatStatistics()
    @State private var pointSplatReprojection = true
    @State private var pointSplatSupersamplingSetting = 2
    @State private var pointSplatPointsPerThreadSetting = 4
    /// Scratch + output buffers for the GPU sorter (``SplatRenderer/gpu``).
    @State private var sortResources: GPUSortResources
    /// Seed for the stochastic renderer's noise pattern. Advances once per
    /// camera/model change, so the pattern varies while moving but freezes
    /// when the view is stationary, avoiding constant shimmer (#51).
    @State private var stochasticSeed: UInt32 = 0

    /// Superseded index buffers are held for this many results before release so
    /// the GPU can finish rendering with them. Sized to cover MTKView's typical
    /// in-flight frame count (3) plus a margin.
    private static let pendingReleaseDepth = 3


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
            capacity: splatCloud.count,
            preallocatedBufferCount: Self.pendingReleaseDepth + 3
        ))
        _sortResources = State(initialValue: try! GPUSortResources(device: device, capacity: splatCloud.count))
    }

    public var body: some View {
        RenderView { context, drawableSize in
            let projectionMatrix = projection.projectionMatrix(for: drawableSize)
            let size = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
            switch renderer {
            case .spark:
                if let sortedIndices {
                    try RenderPass {
                        try SparkSplatRenderPipeline(
                            splatCloud: splatCloud,
                            projectionMatrix: projectionMatrix,
                            modelMatrix: modelMatrix,
                            cameraMatrix: cameraMatrix,
                            drawableSize: size,
                            sortedIndices: sortedIndices
                        )
                    }
                    .renderPassDescriptorModifier { descriptor in
                        descriptor.renderTargetArrayLength = 1
                    }
                }
            case .gpu:
                try GPUSortedSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: size,
                    resources: sortResources
                )
            case .tileBased:
                try TileBasedSplatPass(
                    splatCloud: splatCloud,
                    projection: projection,
                    drawableSize: size,
                    cameraMatrix: cameraMatrix,
                    modelMatrix: modelMatrix
                )
            case .stochastic:
                try RenderPass {
                    try StochasticSplatRenderPipeline(
                        splatCloud: splatCloud,
                        projectionMatrix: projectionMatrix,
                        modelMatrix: modelMatrix,
                        cameraMatrix: cameraMatrix,
                        drawableSize: size,
                        frameTime: stochasticSeed
                    )
                    .depthCompare(function: .less, enabled: true)
                }
                .renderPassDescriptorModifier { descriptor in
                    descriptor.renderTargetArrayLength = 1
                }
            case .pointSplat:
                // PointSplat's fixed-point depth needs a finite range; derive
                // it from the projection (reversed-infinite-Z gets a finite
                // far solely for quantization).
                let depthRange: ClosedRange<Float> = switch projection.depthMode {
                case .standard(let zClip):
                    zClip
                case .reversed(let zMin):
                    zMin...1_000
                }
                try PointSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: size,
                    frameIndex: UInt32(truncatingIfNeeded: context.frameUniforms.index),
                    depthRange: depthRange,
                    supersampling: pointSplatSupersamplingSetting,
                    pointsPerThread: pointSplatPointsPerThreadSetting,
                    reprojection: pointSplatReprojection,
                    statistics: pointSplatStatistics
                )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if renderer == .tileBased {
                Text("Work in progress")
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding()
            }
            if renderer == .pointSplat {
                pointSplatStats
            }
            if renderer == .gpu {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let total = splatCloud.count
                    let survivors = min(sortResources.lastSurvivorCount, total)
                    let culledPercent = total > 0 ? Double(total - survivors) / Double(total) * 100 : 0
                    Group {
                        #if os(macOS)
                        Form {
                            LabeledContent("Splats", value: "\(survivors.formatted()) / \(total.formatted())")
                            LabeledContent("Culled", value: "\(culledPercent.formatted(.number.precision(.fractionLength(1))))%")
                        }
                        #else
                        VStack(spacing: 4) {
                            LabeledContent("Splats", value: "\(survivors.formatted()) / \(total.formatted())")
                            LabeledContent("Culled", value: "\(culledPercent.formatted(.number.precision(.fractionLength(1))))%")
                        }
                        .fixedSize()
                        #endif
                    }
                    .monospacedDigit()
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding()
                }
            }
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .metalDepthStencilPixelFormat(renderer == .stochastic ? .depth32Float : .invalid)
        .task {
            if renderer == .spark {
                sortManager.requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
            }
            for await indices in sortManager.managedSortedIndicesStream(pendingReleaseDepth: Self.pendingReleaseDepth) {
                sortedIndices = indices
            }
        }
        .onChange(of: splatCloud, initial: false) { _, newCloud in
            Task {
                await sortManager.setSplatCloud(newCloud)
                if renderer == .spark {
                    sortManager.requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
                }
            }
        }
        .onChange(of: cameraMatrix) {
            stochasticSeed &+= 1
            if renderer == .spark {
                sortManager.requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
            }
        }
        .onChange(of: modelMatrix) {
            stochasticSeed &+= 1
            if renderer == .spark {
                sortManager.requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
            }
        }
        .onChange(of: renderer) {
            if renderer == .spark {
                sortManager.requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
            }
        }
    }

    /// PointSplat constants overlay: splat count, sampling settings, and the
    /// derived per-frame point budget for the current view size.
    private var pointSplatStats: some View {
        GeometryReader { proxy in
            let supersampling = pointSplatSupersamplingSetting
            let pointsPerThread = pointSplatPointsPerThreadSetting
            let pixelWidth = Int(proxy.size.width * displayScale)
            let pixelHeight = Int(proxy.size.height * displayScale)
            let pixels = pixelWidth * pixelHeight
            let budget = PointSplatWorkloadDistributor.capacity(forSupersampledPixels: pixels * supersampling * supersampling, pointsPerThread: pointsPerThread) * pointsPerThread
            let megapixels = Double(pixels) / 1_000_000
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Splats", value: splatCloud.count.formatted())
                LabeledContent("Size", value: "\(Int(proxy.size.width))\u{00D7}\(Int(proxy.size.height))\u{00D7}\(Double(displayScale).formatted(.number.precision(.fractionLength(0...1)))) (\(megapixels.formatted(.number.precision(.fractionLength(1)))) MP)")
                LabeledContent("Supersampling") {
                    Picker("Supersampling", selection: $pointSplatSupersamplingSetting) {
                        Text("1\u{00D7}1").tag(1)
                        Text("2\u{00D7}2").tag(2)
                        Text("4\u{00D7}4").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .fixedSize()
                }
                LabeledContent("Points/thread (K)") {
                    Picker("Points/thread", selection: $pointSplatPointsPerThreadSetting) {
                        ForEach([1, 4, 8, 16], id: \.self) { value in
                            Text(value.formatted()).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .fixedSize()
                }
                LabeledContent("Point budget", value: budget.formatted(.number.notation(.compactName)))
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let demand = pointSplatStatistics.pointDemand
                    let used = pointSplatStatistics.pointCount
                    LabeledContent("Points", value: "\(used.formatted(.number.notation(.compactName))) / \(demand.formatted(.number.notation(.compactName)))")
                        .foregroundStyle(demand > budget ? .orange : .white)
                }
                LabeledContent("SH degree", value: splatCloud.shCoefficients != nil ? splatCloud.shDegree.formatted() : "off")
                Toggle("Reproject", isOn: $pointSplatReprojection)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .fixedSize()
            .monospacedDigit()
            .font(.caption)
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding()
        }
    }
}

#endif

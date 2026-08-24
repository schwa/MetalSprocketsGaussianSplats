#if !arch(x86_64)
import GeometryLite3D
import Metal
import MetalSprockets
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Splats
import Testing

/// Regression tests for stereo culling in the GPU sort path (#56). A splat that
/// is visible to only one eye must survive the cull when both views are given.
@Suite("GPUSplatSort stereo cull", .enabled(if: MetalTestSupport.supports64BitAtomics))
struct GPUSplatSortStereoTests {
    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noMetalDevice
        }
        self.device = device
    }

    private func makeCloud(position: SIMD3<Float>) throws -> GPUSplatCloud<SparkSplat> {
        let splat = SparkSplat(
            position: simd_half3(Float16(position.x), Float16(position.y), Float16(position.z)),
            scale: simd_half3(repeating: 0.1),
            rotation: simd_half4(0, 0, 0, 1),
            color: simd_uchar4(128, 128, 128, 255)
        )
        return try GPUSplatCloud<SparkSplat>(device: device, splats: [splat])
    }

    private var projectionMatrix: simd_float4x4 {
        PerspectiveProjection(
            verticalAngleOfView: .degrees(60),
            depthMode: .standard(zClip: 0.01 ... 100)
        )
        .projectionMatrix(for: CGSize(width: 64, height: 64))
    }

    /// Runs the cull and sort for the given views. Returns the survivor count
    /// from the indirect draw args of the slot.
    @MainActor
    private func survivorCount(cloud: GPUSplatCloud<SparkSplat>, cameraMatrices: [simd_float4x4]) throws -> Int {
        let resources = try GPUSortResources(device: device, capacity: cloud.count)
        let slotIndex = resources.advance()
        let pass = try GPUSplatSortComputePass(
            splatCloud: cloud,
            projectionMatrices: cameraMatrices.map { _ in projectionMatrix },
            modelMatrix: .identity,
            cameraMatrices: cameraMatrices,
            resources: resources,
            slotIndex: slotIndex
        )
        let renderer = try OffscreenRenderer(size: CGSize(width: 64, height: 64))
        _ = try renderer.render(pass)
        let drawArgs = resources.slots[slotIndex].drawArgs.contents().bindMemory(to: UInt32.self, capacity: 4)
        return Int(drawArgs[1])
    }

    @Test("splat visible only to the second eye survives the stereo cull")
    @MainActor
    func stereoCullKeepsSplatVisibleToEitherEye() throws {
        // The splat is in front of the origin. The seeing camera sits at the
        // origin and looks down -z. The blind camera is far off to the side.
        let cloud = try makeCloud(position: SIMD3<Float>(0, 0, -2))
        let seeingCamera = simd_float4x4.identity
        let blindCamera = simd_float4x4(translation: SIMD3<Float>(1_000, 0, 0))

        #expect(try survivorCount(cloud: cloud, cameraMatrices: [blindCamera]) == 0)
        #expect(try survivorCount(cloud: cloud, cameraMatrices: [seeingCamera, blindCamera]) == 1)
        #expect(try survivorCount(cloud: cloud, cameraMatrices: [blindCamera, seeingCamera]) == 1)
    }

    @Test("mono cull keeps a visible splat")
    @MainActor
    func monoCullKeepsVisibleSplat() throws {
        let cloud = try makeCloud(position: SIMD3<Float>(0, 0, -2))
        #expect(try survivorCount(cloud: cloud, cameraMatrices: [.identity]) == 1)
    }

    @Test("GPU-sorted pipeline renders debug modes")
    @MainActor
    func gpuSortedPipelineRendersDebugMode() throws {
        let cloud = try makeCloud(position: SIMD3<Float>(0, 0, -2))
        let resources = try GPUSortResources(device: device, capacity: cloud.count)
        let pipeline = try GPUSortedSplatRenderPipeline(
            splatCloud: cloud,
            projectionMatrix: projectionMatrix,
            modelMatrix: .identity,
            cameraMatrix: .identity,
            drawableSize: SIMD2<Float>(64, 64),
            debugParams: .opacity,
            resources: resources
        )
        let renderer = try OffscreenRenderer(size: CGSize(width: 64, height: 64))

        #expect(throws: Never.self) {
            try renderer.render(pipeline)
        }
    }
}
#endif

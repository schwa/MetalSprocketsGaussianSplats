#if !arch(x86_64)
import CoreGraphics
import Foundation
import GeometryLite3D
import GoldenImage
import Metal
import MetalSprockets
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
@testable import Splats
import Testing

@Suite(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "Golden image tests are GPU-dependent and not reliable on CI"))
struct GoldenImageRenderingTests {
    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderTestError.noMetalDevice
        }
        self.device = device
    }

    // MARK: - Spark Renderer Tests

    @Test @MainActor
    func testSparkRenderTestGrid() throws {
        let image = try renderSplatsWithSpark(
            fixture: "test-grid",
            extension: "spz",
            cameraPosition: [0.1, 5, 5],
            size: CGSize(width: 512, height: 512)
        )
        try compareGoldenImage(image, named: "SparkTestGrid")
    }

    @Test @MainActor
    func testSparkRenderTestGridAlternateAngle() throws {
        let image = try renderSplatsWithSpark(
            fixture: "test-grid",
            extension: "spz",
            cameraPosition: [4, -1, 2],
            size: CGSize(width: 512, height: 512)
        )
        try compareGoldenImage(image, named: "SparkTestGridAlternateAngle")
    }

    @Test @MainActor
    func testSparkRenderButterflyWithAndWithoutSH() throws {
        // The butterfly sample carries degree-3 SH; render with SH
        // (view-dependent color) and without, against separate goldens, and
        // require that SH actually changes the image (guards against SH
        // silently not being applied — test-ring.sog turned out to have no
        // SH at all, which made an earlier version of this test vacuous).
        let cloud = try loadButterflyCloud()
        #expect(cloud.shCoefficients != nil, "sample is expected to carry SH")

        let withSH = try renderSparkCloud(cloud: cloud, cameraPosition: [0, 0.5, 1.5], size: CGSize(width: 512, height: 512), useSphericalHarmonics: true)
        try compareGoldenImage(withSH, named: "SparkButterflySH")

        let withoutSH = try renderSparkCloud(cloud: cloud, cameraPosition: [0, 0.5, 1.5], size: CGSize(width: 512, height: 512), useSphericalHarmonics: false)
        try compareGoldenImage(withoutSH, named: "SparkButterflyNoSH")

        #expect(!imagesAreIdentical(withSH, withoutSH), "SH should change the rendered image")
    }

    /// Loads the butterfly sample (Samples/, too large to duplicate into
    /// test resources) with its SH coefficients, resolved relative to this
    /// source file.
    private func loadButterflyCloud() throws -> GPUSplatCloud<SparkSplat> {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Samples/butterfly-wings-closed.spz")
        let reader = try SplatReader(url: url)
        let shDegree = reader.shDegree
        var splats: [SparkSplat] = []
        var shCoefficients: [Float] = []
        try reader.read { _, extendedSplat in
            splats.append(SparkSplat(extendedSplat.genericSplat))
            if let sh = extendedSplat.sphericalHarmonics {
                for coefficient in sh {
                    shCoefficients.append(contentsOf: coefficient)
                }
            }
        }
        if shDegree > 0, !shCoefficients.isEmpty {
            return try GPUSplatCloud<SparkSplat>(device: device, splats: splats, shCoefficients: shCoefficients, shDegree: shDegree)
        }
        return try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
    }

    private func imagesAreIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let dataA = a.dataProvider?.data as Data?, let dataB = b.dataProvider?.data as Data? else {
            return false
        }
        return dataA == dataB
    }

    // MARK: - Helpers

    private func loadSplats(fixture: String, extension ext: String) throws -> [GenericSplat] {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: ext, subdirectory: "Fixtures"))
        let reader = try SplatReader(url: url)
        var splats: [GenericSplat] = []
        try reader.read { _, extendedSplat in
            splats.append(extendedSplat.genericSplat)
        }
        return splats
    }

    private func makeCameraMatrix(position: SIMD3<Float>, target: SIMD3<Float> = .zero) -> simd_float4x4 {
        LookAt(position: position, target: target, up: SIMD3<Float>(0, 1, 0)).cameraMatrix
    }

    private func makeProjectionMatrix(size: CGSize) -> simd_float4x4 {
        let projection = PerspectiveProjection(
            verticalAngleOfView: .degrees(60),
            depthMode: .standard(zClip: 0.01 ... 100)
        )
        return projection.projectionMatrix(for: size)
    }

    @MainActor
    private func renderSplatsWithSpark(fixture: String, extension ext: String, cameraPosition: SIMD3<Float>, size: CGSize) throws -> CGImage {
        let genericSplats = try loadSplats(fixture: fixture, extension: ext)
        let gpuSplats = genericSplats.map { SparkSplat($0) }
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: gpuSplats)
        return try renderSparkCloud(cloud: cloud, cameraPosition: cameraPosition, size: size)
    }

    @MainActor
    private func renderSparkCloud(cloud: GPUSplatCloud<SparkSplat>, cameraPosition: SIMD3<Float>, size: CGSize, useSphericalHarmonics: Bool? = nil) throws -> CGImage {
        let sortManager = try AsyncSortManager<SparkSplat>(device: device, splatCloud: cloud, capacity: cloud.count)

        let cameraMatrix = makeCameraMatrix(position: cameraPosition)
        let projectionMatrix = makeProjectionMatrix(size: size)
        let sortParameters = SortParameters(camera: cameraMatrix, model: .identity)
        let sortedIndices = sortManager.sortNowSync(sortParameters)

        let renderer = try OffscreenRenderer(size: size)
        let renderPass = try RenderPass {
            try SparkSplatRenderPipeline(
                splatCloud: cloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: .identity,
                cameraMatrix: cameraMatrix,
                drawableSize: SIMD2<Float>(Float(size.width), Float(size.height)),
                convertSRGBToLinear: false,
                useSphericalHarmonics: useSphericalHarmonics,
                sortedIndices: sortedIndices
            )
        }
        .renderPassDescriptorModifier { descriptor in
            descriptor.renderTargetArrayLength = 1
        }
        let rendering = try renderer.render(renderPass)
        return try rendering.cgImage
    }

    private func compareGoldenImage(_ image: CGImage, named name: String) throws {
        let goldenImagesDir = try #require(Bundle.module.resourceURL?.appendingPathComponent("Golden Images"))
        let comparison = GoldenImageComparison(imageDirectory: goldenImagesDir, options: .none)
        let isMatch = try comparison.image(image: image, matchesGoldenImageNamed: name)
        #expect(isMatch)
    }
}

enum RenderTestError: Error {
    case noMetalDevice
}

#endif

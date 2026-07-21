#if !arch(x86_64)
import CoreGraphics
import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
@testable import Splats
import Testing

/// RFC 0003 verification: a converged PointSplat render should match the
/// Spark (sorted alpha-blended) renderer on the same scene. Differences in
/// aliasing and residual noise are expected, so the PSNR bar is modest —
/// it catches orientation flips, projection mismatches, and packing bugs,
/// not subtle shading differences.
@Suite("PointSplatConvergence")
struct PointSplatConvergenceTests {
    enum TestError: Error {
        case noMetalDevice
        case bufferAllocationFailed
    }

    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noMetalDevice
        }
        self.device = device
    }

    @Test("converged PointSplat matches Spark render")
    @MainActor
    func matchesSparkRender() throws {
        let size = 256
        let cameraPosition = SIMD3<Float>(0.1, 5, 5)

        let url = try #require(Bundle.module.url(forResource: "test-grid", withExtension: "spz", subdirectory: "Fixtures"))
        let reader = try SplatReader(url: url)
        var splats: [SparkSplat] = []
        try reader.read { _, extendedSplat in
            splats.append(SparkSplat(extendedSplat.genericSplat))
        }

        let cameraMatrix = LookAt(position: cameraPosition, target: .zero, up: SIMD3<Float>(0, 1, 0)).cameraMatrix
        let projection = PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01...100))
        let projectionMatrix = projection.projectionMatrix(for: CGSize(width: size, height: size))

        // Reference: Spark renderer.
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
        let sortedIndices = try SplatSorter.sort(device: device, splatCloud: cloud, parameters: SortParameters(camera: cameraMatrix, model: .identity))
        let offscreen = try OffscreenRenderer(size: CGSize(width: size, height: size))
        let renderPass = try RenderPass {
            try SparkSplatRenderPipeline(
                splatCloud: cloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: .identity,
                cameraMatrix: cameraMatrix,
                drawableSize: SIMD2<Float>(Float(size), Float(size)),
                convertSRGBToLinear: false,
                sortedIndices: sortedIndices
            )
        }
        .renderPassDescriptorModifier { descriptor in
            descriptor.renderTargetArrayLength = 1
        }
        let sparkImage = try offscreen.render(renderPass).cgImage
        let sparkPixels = try rgbPixels(from: sparkImage)

        // Candidate: PointSplat accumulated over many stochastic frames.
        let renderer = try PointSplatRenderer(device: device, configuration: .init(width: size, height: size, maxPointsPerFrame: 2_000_000))
        guard let buffer = device.makeBuffer(bytes: splats, length: MemoryLayout<SparkSplat>.stride * splats.count) else {
            throw TestError.bufferAllocationFailed
        }
        var accumulated = [SIMD3<Float>](repeating: .zero, count: size * size)
        let frames = 128
        for frame in 0..<frames {
            let texture = try renderer.render(splats: buffer, splatCount: splats.count, modelMatrix: .identity, viewMatrix: cameraMatrix.inverse, projectionMatrix: projectionMatrix, frameSeed: UInt32(frame))
            var pixels = [SIMD4<Float>](repeating: .zero, count: size * size)
            pixels.withUnsafeMutableBytes { pointer in
                texture.getBytes(pointer.baseAddress!, bytesPerRow: size * MemoryLayout<SIMD4<Float>>.stride, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            }
            for i in 0..<accumulated.count {
                accumulated[i] += SIMD3<Float>(pixels[i].x, pixels[i].y, pixels[i].z)
            }
        }
        let pointSplatPixels = accumulated.map { $0 / Float(frames) }

        // PSNR over RGB.
        var sumSquaredError = 0.0
        for i in 0..<pointSplatPixels.count {
            let delta = pointSplatPixels[i] - sparkPixels[i]
            sumSquaredError += Double(simd_dot(delta, delta))
        }
        let meanSquaredError = sumSquaredError / Double(pointSplatPixels.count * 3)
        let psnr = 10.0 * log10(1.0 / max(meanSquaredError, 1e-12))
        #expect(psnr > 30.0, "PSNR vs Spark: \(psnr) dB")
    }

    /// Extracts RGB float pixels from a rendered CGImage, undoing the sRGB
    /// encode applied by the render target so values compare against the
    /// raw splat colors PointSplat resolves.
    private func rgbPixels(from image: CGImage) throws -> [SIMD3<Float>] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func decode(_ value: UInt8) -> Float {
            let scaled = Float(value) / 255.0
            return scaled <= 0.04045 ? scaled / 12.92 : pow((scaled + 0.055) / 1.055, 2.4)
        }
        // The Spark pipeline writes raw (sRGB-encoded) splat colors into an
        // sRGB render target, which linearizes on store; decoding the PNG
        // bytes recovers the raw values.
        return (0..<(width * height)).map { i in
            SIMD3<Float>(decode(bytes[i * 4]), decode(bytes[i * 4 + 1]), decode(bytes[i * 4 + 2]))
        }
    }
}
#endif

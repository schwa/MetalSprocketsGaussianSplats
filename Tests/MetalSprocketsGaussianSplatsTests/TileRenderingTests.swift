#if !arch(x86_64)
import CoreGraphics
import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Testing

/// Smoke tests for the tile-based renderer.
///
/// An opaque splat in front of the camera must produce visible, correctly
/// colored output. The test guards the precomputed-conic fast path (#58).
@Suite(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "GPU-dependent"))
struct TileRenderingTests {
    @Test @MainActor
    func opaqueSplatRendersAtCenter() throws {
        let size = 128
        let red = SparkSplat(position: simd_half3(0, 0, 0), scale: simd_half3(repeating: 0.3), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(255, 0, 0, 255))
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderTestError.noMetalDevice
        }
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: [red])
        let cameraMatrix = LookAt(position: SIMD3<Float>(0, 0, 2.5), target: .zero, up: SIMD3<Float>(0, 1, 0)).cameraMatrix
        let projection = PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01...100))

        let renderer = try OffscreenRenderer(size: CGSize(width: size, height: size))
        let pass = try TileBasedSplatPass(
            splatCloud: cloud,
            projection: projection,
            drawableSize: SIMD2<Float>(Float(size), Float(size)),
            cameraMatrix: cameraMatrix
        )
        let rendering = try renderer.render(pass)
        let image = try rendering.cgImage

        let pixels = try #require(image.dataProvider?.data as Data?)
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        // Offscreen renders come back as byteOrder32Little/premultipliedFirst,
        // that is B,G,R,A byte order.
        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            return (pixels[offset + 2], pixels[offset + 1], pixels[offset])
        }

        let center = pixel(size / 2, size / 2)

        #expect(center.r > 128, "center should be strongly red, got \(center)")
        #expect(center.g < 64, "center \(center)")
        #expect(center.b < 64, "center \(center)")

        let corner = pixel(2, 2)
        #expect(corner.r < 32, "corner should be background, got \(corner)")
    }
}

#endif

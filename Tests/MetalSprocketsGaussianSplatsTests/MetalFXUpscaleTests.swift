#if !arch(x86_64) && canImport(MetalFX)
import CoreGraphics
import GeometryLite3D
import Metal
import MetalFX
import MetalSprockets
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Testing

@Suite(.enabled(if: MTLCreateSystemDefaultDevice().map { MTLFXSpatialScalerDescriptor.supportsMetal4FX($0) } ?? false))
struct MetalFXUpscaleTests {
    @Test
    @MainActor
    func sparkUpscalesToFullSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let splat = SparkSplat(position: simd_half3(0, 0, 0), scale: simd_half3(repeating: 0.5), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(255, 0, 0, 255))
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: [splat])
        let renderer = try OffscreenSplatRenderer(
            renderer: .spark,
            splatCloud: cloud,
            projection: PerspectiveProjection(),
            cameraMatrix: simd_float4x4(translation: [0, 0, 3]),
            configuration: .init(width: 128, height: 96, metalFXScale: 2),
            device: device
        )
        #expect(renderer.renderSize == [64, 48])
        try renderer.renderFrame()
        let image = try renderer.makeImage()
        #expect(image.width == 128)
        #expect(image.height == 96)

        // The splat sits at the center, so the center pixel must be red.
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -64, y: -48, width: 128, height: 96))
        let pixel = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        #expect(pixel[0] > 128)
        #expect(pixel[1] < 64)
    }

    @Test
    @MainActor
    func upscaledContentDrawsIntoRenderTarget() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let splat = SparkSplat(position: simd_half3(0, 0, 0), scale: simd_half3(repeating: 0.5), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(0, 255, 0, 255))
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: [splat])
        let renderer = try OffscreenRenderer(size: CGSize(width: 128, height: 96), device: device)
        let targets = try MetalFXUpscaleTargets(device: device)
        let resources = try GPUSortResources(device: device, capacity: cloud.count, slotCount: 1)
        let projection = PerspectiveProjection().projectionMatrix(aspectRatio: 128 / 96)
        let rendering = try renderer.render(
            MetalFXUpscaledContent(targets: targets, inputSize: [64, 48], outputSize: [128, 96], pixelFormat: .bgra8Unorm_srgb) {
                try GPUSortedSplatRenderPipeline(splatCloud: cloud, projectionMatrix: projection, modelMatrix: .identity, cameraMatrix: simd_float4x4(translation: [0, 0, 3]), drawableSize: [64, 48], resources: resources)
            }
        )
        let image = try rendering.texture.toCGImage()
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -64, y: -48, width: 128, height: 96))
        let pixel = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        #expect(pixel[1] > 128)
        #expect(pixel[0] < 64)
    }
}
#endif

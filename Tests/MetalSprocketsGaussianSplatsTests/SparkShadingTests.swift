#if !arch(x86_64)
import CoreGraphics
import GeometryLite3D
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Splats
import Testing

@Suite("Spark shading matches INRIA/gsplat")
struct SparkShadingTests {
    // INRIA: color = 0.5 + C0*dc - C1*y*sh1 + C1*z*sh2 - C1*x*sh3, dir = position - camera.
    // With only sh3.r = 1 and the camera on +X, dir = -X, so red rises above the base color.
    @Test @MainActor
    func degree1XBasisSign() throws {
        var coefficients = [Float](repeating: 0, count: 9)
        coefficients[6] = 1
        let fromPositiveX = try centerPixel(cameraPosition: [3, 0, 0], shCoefficients: coefficients, shDegree: 1)
        let fromNegativeX = try centerPixel(cameraPosition: [-3, 0, 0], shCoefficients: coefficients, shDegree: 1)
        #expect(fromPositiveX.x > fromNegativeX.x + 0.2)
    }

    // INRIA degree 1, y term: -C1*y*sh1. Camera on +Y gives dir = -Y, so red rises.
    @Test @MainActor
    func degree1YBasisSign() throws {
        var coefficients = [Float](repeating: 0, count: 9)
        coefficients[0] = 1
        let fromPositiveY = try centerPixel(cameraPosition: [0, 3, 0.001], shCoefficients: coefficients, shDegree: 1)
        let fromNegativeY = try centerPixel(cameraPosition: [0, -3, 0.001], shCoefficients: coefficients, shDegree: 1)
        #expect(fromPositiveY.x > fromNegativeY.x + 0.2)
    }

    // INRIA degree 3, term 5: 1.4453 * z * (xx - yy). From cameras at (-3, 0, ∓3),
    // dir = (√½, 0, ±√½), so xx - yy = ½ and only the sign of z changes.
    @Test @MainActor
    func degree3Term5Magnitude() throws {
        var coefficients = [Float](repeating: 0, count: 45)
        coefficients[39] = 0.2
        let positiveZ = try centerPixel(cameraPosition: [-3, 0, -3], shCoefficients: coefficients, shDegree: 3)
        let negativeZ = try centerPixel(cameraPosition: [-3, 0, 3], shCoefficients: coefficients, shDegree: 3)
        let halfRoot = Float(0.5).squareRoot()
        let expected: Float = 2 * 1.445305721320277 * halfRoot * 0.5 * 0.2
        let difference = positiveZ.x - negativeZ.x
        #expect(abs(difference - expected) < 0.05, "difference \(difference), expected \(expected)")
    }

    // MARK: - Helpers

    @MainActor
    private func centerPixel(cameraPosition: SIMD3<Float>, shCoefficients: [Float], shDegree: UInt8, baseColor: SIMD3<Float> = [0.5, 0.5, 0.5]) throws -> SIMD3<Float> {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let generic = GenericSplat(position: .zero, scale: [0.5, 0.5, 0.5], color: SIMD4(baseColor, 1), rotation: [0, 0, 0, 1])
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: [SparkSplat(generic)], shCoefficients: shCoefficients, shDegree: shDegree)
        let size = 32
        let renderer = try OffscreenSplatRenderer(
            renderer: .spark,
            splatCloud: cloud,
            projection: PerspectiveProjection(verticalAngleOfView: .degrees(30), depthMode: .standard(zClip: 0.01 ... 100)),
            cameraMatrix: LookAt(position: cameraPosition, target: .zero, up: [0, 1, 0]).cameraMatrix,
            configuration: .init(width: size, height: size, convertSRGBToLinear: false),
            device: device
        )
        try renderer.renderFrame()
        let image = try renderer.makeImage()
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let context = try #require(CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let index = (size / 2 * size + size / 2) * 4
        return SIMD3(linear(bytes[index]), linear(bytes[index + 1]), linear(bytes[index + 2]))
    }

    // The offscreen target is bgra8Unorm_srgb, so decode back to the shader's linear output.
    private func linear(_ byte: UInt8) -> Float {
        let value = Float(byte) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
#endif

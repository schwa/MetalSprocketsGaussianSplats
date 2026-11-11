#if !arch(x86_64)
import Foundation
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Splats

private let supportedExtensions: Set<String> = ["sog", "ply", "splat", "spz"]

private func floatsPerSplat(degree: Int) -> Int {
    3 * ((degree + 1) * (degree + 1) - 1)
}

/// Loads a scene, keeping at most `maximumDegree` SH bands. Throws ``SceneError``.
func loadScene(path: String, maximumDegree: Int?, device: MTLDevice) throws -> GPUSplatCloud<SparkSplat> {
    let url = URL(fileURLWithPath: path)
    let pathExtension = url.pathExtension.lowercased()
    guard supportedExtensions.contains(pathExtension) else {
        let shown = pathExtension.isEmpty ? "extensionless" : ".\(pathExtension)"
        throw SceneError("\(shown) scenes are not supported")
    }
    guard FileManager.default.isReadableFile(atPath: path) else {
        throw SceneError("cannot read scene \(path): no such file")
    }
    let result: SplatBufferResult
    do {
        result = try SplatLoader.read(device: device, url: url)
    } catch {
        throw SceneError("cannot read scene \(path): \(error)")
    }

    let fileDegree = Int(result.shDegree)
    let degree = min(fileDegree, maximumDegree ?? fileDegree)
    if degree == fileDegree {
        return GPUSplatCloud(result)
    }
    if degree == 0 {
        return GPUSplatCloud(splats: result.splats, shDegree: 0)
    }
    // The shader strides the SH buffer by the cloud's degree, so keep the
    // leading coefficients of each row.
    let oldStride = floatsPerSplat(degree: fileDegree)
    let newStride = floatsPerSplat(degree: degree)
    let rows = result.shCoefficients.count / oldStride
    var coefficients = [Float](repeating: 0, count: max(rows * newStride, 1))
    result.shCoefficients.withUnsafeBufferPointer { source in
        for row in 0..<rows {
            for index in 0..<newStride {
                coefficients[row * newStride + index] = source[row * oldStride + index]
            }
        }
    }
    let buffer = try device.makeTypedBuffer(values: coefficients, options: [.storageModeShared]).labeled("SHCoefficients (degree \(degree))")
    return GPUSplatCloud(splats: result.splats, shCoefficients: buffer, shDegree: UInt8(degree))
}
#endif

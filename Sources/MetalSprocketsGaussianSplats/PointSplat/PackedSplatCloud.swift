#if !arch(x86_64)

import Metal
import MetalSprocketsGaussianSplatShaders
import simd
import Splats

/// Quantized splat storage for the PointSplat renderer (issue #77).
///
/// Packs each 32-byte ``SparkSplat`` into an 18-byte ``GPSPackedSplat``:
/// 16-bit fixed-point means inside the cloud AABB, 10-bit log-space
/// scales, a smallest-three 30-bit quaternion, and 8-bit color + opacity.
/// The GPU decodes back to `SparkSplat` on load, so quality loss is
/// limited to quantization error while splat-stage read bandwidth drops
/// by ~44%.
public struct PackedSplatCloud {
    public let buffer: MTLBuffer
    public let bounds: GPSPackedSplatBounds
    public let count: Int

    public init(device: MTLDevice, splats: [SparkSplat]) throws {
        guard !splats.isEmpty else {
            throw PointSplatError.emptyCloud
        }
        let (elements, bounds) = Self.pack(splats)
        guard let buffer = device.makeBuffer(bytes: elements, length: MemoryLayout<GPSPackedSplat>.stride * elements.count) else {
            throw PointSplatError.bufferAllocationFailed
        }
        buffer.label = "Packed splats"
        self.buffer = buffer
        self.bounds = bounds
        count = elements.count
    }

    /// 1/sqrt(2): magnitude bound for the three stored quaternion components.
    private static let quaternionLimit: Float = 0.7071067811865476

    /// Quantizes splats and computes the dequantization bounds.
    public static func pack(_ splats: [SparkSplat]) -> (elements: [GPSPackedSplat], bounds: GPSPackedSplatBounds) {
        var positionMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var positionMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var logScaleMin = Float.greatestFiniteMagnitude
        var logScaleMax = -Float.greatestFiniteMagnitude
        for splat in splats {
            let position = SIMD3<Float>(Float(splat.position.x), Float(splat.position.y), Float(splat.position.z))
            positionMin = simd_min(positionMin, position)
            positionMax = simd_max(positionMax, position)
            for scale in [Float(splat.scale.x), Float(splat.scale.y), Float(splat.scale.z)] where scale > 0 {
                logScaleMin = min(logScaleMin, log(scale))
                logScaleMax = max(logScaleMax, log(scale))
            }
        }
        if logScaleMin > logScaleMax {
            // Every scale was zero; any range works, alpha is zeroed below.
            logScaleMin = 0
            logScaleMax = 0
        }
        let positionExtent = simd_max(positionMax - positionMin, SIMD3<Float>(repeating: 1e-9))
        let logScaleExtent = max(logScaleMax - logScaleMin, 1e-6)
        let bounds = GPSPackedSplatBounds(positionMin: positionMin, positionExtent: positionExtent, logScaleMin: logScaleMin, logScaleExtent: logScaleExtent)

        func quantize(_ value: Float, steps: Float) -> UInt32 {
            UInt32((value.clamped(to: 0...1) * steps).rounded())
        }

        let elements = splats.map { splat -> GPSPackedSplat in
            let position = SIMD3<Float>(Float(splat.position.x), Float(splat.position.y), Float(splat.position.z))
            let positionT = (position - positionMin) / positionExtent
            let px = UInt16(quantize(positionT.x, steps: 65_535))
            let py = UInt16(quantize(positionT.y, steps: 65_535))
            let pz = UInt16(quantize(positionT.z, steps: 65_535))

            let scales = SIMD3<Float>(Float(splat.scale.x), Float(splat.scale.y), Float(splat.scale.z))
            let degenerate = scales.x <= 0 || scales.y <= 0 || scales.z <= 0
            var scaleBits: UInt32 = 0
            if !degenerate {
                let logT = (SIMD3<Float>(log(scales.x), log(scales.y), log(scales.z)) - logScaleMin) / logScaleExtent
                scaleBits = (quantize(logT.x, steps: 1_023) << 20) | (quantize(logT.y, steps: 1_023) << 10) | quantize(logT.z, steps: 1_023)
            }

            var rotation = SIMD4<Float>(Float(splat.rotation.x), Float(splat.rotation.y), Float(splat.rotation.z), Float(splat.rotation.w))
            let length = simd_length(rotation)
            rotation = length > 0 ? rotation / length : SIMD4<Float>(0, 0, 0, 1)
            var maxIndex = 0
            for index in 1..<4 where abs(rotation[index]) > abs(rotation[maxIndex]) {
                maxIndex = index
            }
            if rotation[maxIndex] < 0 {
                rotation = -rotation
            }
            var rotationBits = UInt32(maxIndex) << 30
            var slot = 0
            for index in 0..<4 where index != maxIndex {
                let normalized = (rotation[index] / quaternionLimit + 1) / 2
                rotationBits |= quantize(normalized, steps: 1_023) << (20 - 10 * slot)
                slot += 1
            }

            // The renderer rejects all-zero scales; quantization can't
            // represent zero, so zero the opacity instead.
            let alpha = degenerate ? 0 : splat.color.w
            return GPSPackedSplat(
                position: (px, py, pz),
                scale: (UInt16(scaleBits & 0xFFFF), UInt16(scaleBits >> 16)),
                rotation: (UInt16(rotationBits & 0xFFFF), UInt16(rotationBits >> 16)),
                color: (splat.color.x, splat.color.y, splat.color.z, alpha)
            )
        }
        return (elements, bounds)
    }

    /// CPU mirror of the GPU decode, for tests.
    public static func unpack(_ element: GPSPackedSplat, bounds: GPSPackedSplatBounds) -> SparkSplat {
        let positionT = SIMD3<Float>(Float(element.position.0), Float(element.position.1), Float(element.position.2)) / 65_535
        let position = bounds.positionMin + positionT * bounds.positionExtent

        let scaleBits = UInt32(element.scale.0) | (UInt32(element.scale.1) << 16)
        let logT = SIMD3<Float>(Float((scaleBits >> 20) & 0x3FF), Float((scaleBits >> 10) & 0x3FF), Float(scaleBits & 0x3FF)) / 1_023
        let logScale = bounds.logScaleMin + logT * bounds.logScaleExtent
        let scale = SIMD3<Float>(exp(logScale.x), exp(logScale.y), exp(logScale.z))

        let rotationBits = UInt32(element.rotation.0) | (UInt32(element.rotation.1) << 16)
        let maxIndex = Int(rotationBits >> 30)
        var components = [Float]()
        for shift in [UInt32(20), 10, 0] {
            components.append((Float((rotationBits >> shift) & 0x3FF) / 1_023 * 2 - 1) * quaternionLimit)
        }
        var rotation = SIMD4<Float>()
        var source = 0
        for index in 0..<4 {
            if index == maxIndex {
                continue
            }
            rotation[index] = components[source]
            source += 1
        }
        rotation[maxIndex] = sqrt(max(0, 1 - simd_length_squared(rotation)))

        return SparkSplat(
            position: simd_half3(Float16(position.x), Float16(position.y), Float16(position.z)),
            scale: simd_half3(Float16(scale.x), Float16(scale.y), Float16(scale.z)),
            rotation: simd_half4(Float16(rotation.x), Float16(rotation.y), Float16(rotation.z), Float16(rotation.w)),
            color: simd_uchar4(element.color.0, element.color.1, element.color.2, element.color.3)
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

#endif

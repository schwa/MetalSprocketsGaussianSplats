#if !arch(x86_64)
import Metal
import MetalSprockets
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Splats
import Testing

@Suite(.enabled(if: MetalTestSupport.supports64BitAtomics))
struct GPUSortMultiCloudTests {
    private func splat(depth: Float) -> SparkSplat {
        SparkSplat(position: simd_half3(0, 0, Float16(depth)), scale: simd_half3(repeating: 0.1), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(255, 255, 255, 255))
    }

    @Test(arguments: [SplatSortPrecision.float16, .float32])
    @MainActor
    func mergesCloudsIntoOneOrder(precision: SplatSortPrecision) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Camera looks down -Z. Cloud 1 is shifted so its splats interleave with cloud 0's.
        let cloud0 = try GPUSplatCloud<SparkSplat>(device: device, splats: [splat(depth: -1), splat(depth: -3), splat(depth: -5)])
        let cloud1 = try GPUSplatCloud<SparkSplat>(device: device, splats: [splat(depth: 0), splat(depth: -2)], modelTransform: simd_float4x4(translation: [0, 0, -2]))
        let clouds = [cloud0, cloud1]
        let total = clouds.reduce(0) { $0 + $1.count }

        let resources = try GPUSortResources(device: device, capacity: GPUSortResources.requiredCapacity(for: clouds), slotCount: 1, precision: precision)
        let slot = resources.advance()
        let pass = try GPUSplatSortComputePass(splatClouds: clouds, projectionMatrices: [.identity], modelMatrix: .identity, cameraMatrices: [.identity], cullEnabled: false, resources: resources, slotIndex: slot)
        let runner = try Runner(device: device)
        try runner.run(pass)

        let output = resources.slots[slot].output.unsafeMTLBuffer
        let size = total * MemoryLayout<IndexedDistance>.stride
        let readback = try #require(device.makeBuffer(length: size, options: .storageModeShared))
        try runner.run(
            ComputePass {
                ComputeCommand { encoder in
                    encoder.copy(sourceBuffer: output, sourceOffset: 0, destinationBuffer: readback, destinationOffset: 0, size: size)
                }
                .useComputeResources([output, readback], usage: [.read, .write])
            }
        )
        let indices = Array(UnsafeBufferPointer(start: readback.contents().bindMemory(to: IndexedDistance.self, capacity: total), count: total))
        let pairs = indices.map { [Int($0.cloudIndex), Int($0.splatIndex)] }
        // Back to front (most negative view z first): -5, -4, -3, -2, -1.
        #expect(pairs == [[0, 2], [1, 1], [0, 1], [1, 0], [0, 0]])
    }
}
#endif

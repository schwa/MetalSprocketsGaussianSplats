#if !arch(x86_64)
import Metal
import Testing

// RFC 0003 Phase 0 go/no-go probe. The PointSplat renderer needs 64-bit
// atomic_min on device memory (MSL 3.1, Apple9/Mac2 GPU families).
@Suite("PointSplatAtomicProbe")
struct PointSplatAtomicProbeTests {
    enum ProbeError: Error {
        case noMetalDevice
        case kernelMissing
    }

    static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void atomicMin64Probe(device atomic_ulong *buffer [[buffer(0)]], constant ulong *values [[buffer(1)]], uint tid [[thread_position_in_grid]]) {
        atomic_min_explicit(&buffer[0], values[tid], memory_order_relaxed);
    }
    """

    @Test("device supports 64-bit atomics family")
    func deviceFamilySupport() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeError.noMetalDevice
        }
        #expect(device.supportsFamily(.apple9) || device.supportsFamily(.mac2), "PointSplat requires Apple9 (A17/M3+) or Mac2 for 64-bit atomics")
    }

    // Gated on the same compile probe. The CI runner's virtual GPU reports
    // mac2 but cannot compile MSL 3.1 kernels, so this runs only locally.
    @Test("atomic_min on ulong compiles and computes the minimum", .enabled(if: MetalTestSupport.supports64BitAtomics))
    func atomicMin64() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeError.noMetalDevice
        }
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        let library = try device.makeLibrary(source: Self.kernelSource, options: options)
        guard let function = library.makeFunction(name: "atomicMin64Probe") else {
            throw ProbeError.kernelMissing
        }
        let pipeline = try device.makeComputePipelineState(function: function)

        // Depth-packed style values: the high bits vary, and the minimum wins.
        let count = 4_096
        var values = (0..<count).map { _ in UInt64.random(in: 0..<UInt64.max) }
        let expectedMinimum = values.min() ?? 0
        var initial = UInt64.max

        guard let resultBuffer = device.makeBuffer(bytes: &initial, length: MemoryLayout<UInt64>.stride), let valuesBuffer = device.makeBuffer(bytes: &values, length: MemoryLayout<UInt64>.stride * count), let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ProbeError.noMetalDevice
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(resultBuffer, offset: 0, index: 0)
        encoder.setBuffer(valuesBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let result = resultBuffer.contents().load(as: UInt64.self)
        #expect(result == expectedMinimum)
    }
}
#endif

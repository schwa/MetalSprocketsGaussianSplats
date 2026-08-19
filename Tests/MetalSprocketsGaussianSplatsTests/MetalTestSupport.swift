#if !arch(x86_64)
import Foundation
import Metal

/// Runtime GPU capability probes. These gate tests that need shader features
/// the CI runner's virtualized GPU cannot compile, for example 64-bit device
/// atomics from MSL 3.1. Family checks alone are not enough. The GitHub runner
/// reports `mac2` but fails to compile these kernels, so the probe compiles one
/// kernel to make sure.
enum MetalTestSupport {
    private static let probeSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void atomicMin64Probe(device atomic_ulong *buffer [[buffer(0)]], constant ulong *values [[buffer(1)]], uint tid [[thread_position_in_grid]]) {
        atomic_min_explicit(&buffer[0], values[tid], memory_order_relaxed);
    }
    """

    static let supports64BitAtomics: Bool = {
        // The probe is not reliable on GitHub's virtualized GPU. It can succeed
        // while later compiles of the real shaders fail. Skip the GPU-shader
        // suites on Actions runners.
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil {
            return false
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            return false
        }
        guard device.supportsFamily(.apple9) || device.supportsFamily(.mac2) else {
            return false
        }
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        return (try? device.makeLibrary(source: probeSource, options: options)) != nil
    }()
}
#endif

#if !arch(x86_64)
import SwiftUI

/// The rendering algorithm used by ``SplatView``.
public enum SplatRenderer: String, CaseIterable, Sendable {
    /// CPU-sorted alpha-blended renderer.
    case sparkCPU

    /// The default renderer. It is Spark with a GPU-side sort and frustum
    /// culling. It sorts in the same GPU workload as the render, so there is no
    /// CPU sort latency.
    case sparkGPU

    /// Experimental tile-based renderer. It bins and sorts splats per screen
    /// tile, then composites with an imageblock fragment shader.
    case tileBased = "tile"

    /// Experimental stochastic renderer. It uses random sampling for
    /// transparency. It needs no sort, but the results are noisier.
    case stochastic

    /// Experimental sort-free stochastic point renderer (RFC 0003). It splats
    /// pixel-sized opaque points through 64-bit atomics with temporal
    /// accumulation. It needs the Apple9 or Mac2 GPU families.
    case pointSplat = "point"
}

// MARK: - Environment

private struct SplatRendererKey: EnvironmentKey {
    static let defaultValue: SplatRenderer = .sparkGPU
}

public extension EnvironmentValues {
    /// The splat rendering algorithm to use.
    var splatRenderer: SplatRenderer {
        get { self[SplatRendererKey.self] }
        set { self[SplatRendererKey.self] = newValue }
    }
}

public extension View {
    /// Sets the splat rendering algorithm for any ``SplatView`` in this view hierarchy.
    ///
    /// ```swift
    /// SplatView(splatCloud: cloud, cameraMatrix: camera)
    ///     .splatRenderer(.stochastic)
    /// ```
    func splatRenderer(_ renderer: SplatRenderer) -> some View {
        environment(\.splatRenderer, renderer)
    }
}
#endif

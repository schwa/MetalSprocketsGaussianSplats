#if !arch(x86_64)
import SwiftUI

/// The rendering algorithm used by ``SplatView``.
public enum SplatRenderer: String, CaseIterable, Sendable {
    /// CPU-sorted alpha-blended renderer.
    case spark

    /// The default renderer. Spark with GPU-side sorting and frustum culling;
    /// sorts in the same GPU workload as rendering, so there's no CPU sort latency.
    case gpu

    /// Experimental tile-based renderer. Bins and sorts splats per screen tile
    /// and composites with an imageblock fragment shader.
    case tileBased = "tile"

    /// Experimental stochastic renderer. Uses random sampling for transparency — doesn't require sorting but produces noisier results.
    case stochastic

    /// Experimental sort-free stochastic point renderer (RFC 0003). Splats
    /// pixel-sized opaque points via 64-bit atomics with temporal
    /// accumulation. Requires Apple9/Mac2 GPU families.
    case pointSplat = "point"
}

// MARK: - Environment

private struct SplatRendererKey: EnvironmentKey {
    static let defaultValue: SplatRenderer = .gpu
}

public extension EnvironmentValues {
    /// The splat rendering algorithm to use.
    var splatRenderer: SplatRenderer {
        get { self[SplatRendererKey.self] }
        set { self[SplatRendererKey.self] = newValue }
    }
}

public extension View {
    /// Sets the splat rendering algorithm for any ``SplatView`` within this view hierarchy.
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

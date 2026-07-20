#if !arch(x86_64)
import SwiftUI

/// The rendering algorithm used by ``SplatView``.
public enum SplatRenderer: String, CaseIterable, Sendable {
    /// The default production renderer. Uses sorted alpha blending.
    case spark

    /// Spark renderer with GPU-side sorting and frustum culling. Sorts in the
    /// same GPU workload as rendering; no CPU sort latency.
    case gpu

    /// Experimental stochastic renderer. Uses random sampling for transparency — doesn't require sorting but produces noisier results.
    case stochastic
}

// MARK: - Environment

private struct SplatRendererKey: EnvironmentKey {
    static let defaultValue: SplatRenderer = .spark
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

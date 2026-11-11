#if !arch(x86_64)
import Foundation

/// Runtime-tunable Spark render-quality parameters. Applied as Metal function constants when the pipeline is built,
/// so they are compile-time constants inside the shader but selectable per pipeline.
public struct SplatRenderTuning: Equatable, Sendable {
    /// Gaussian cutoff radius in standard deviations. A smaller value gives
    /// tighter splats (fewer fragments, sharper). A larger value gives softer,
    /// more blurred splats.
    public var maxStdDev: Float
    /// Splats with an alpha less than this value are skipped.
    public var minAlpha: Float
    /// Anti-aliasing covariance dilation in px². A value of 0 disables it. A
    /// higher value inflates and blurs every splat.
    public var blurAmount: Float
    /// Scales opacity by `sqrt(det(cov) / det(cov + blur))` after dilation
    /// (Mip-Splatting / gsplat "antialiased" mode). Off matches INRIA and
    /// gsplat's default "classic" mode.
    public var antialiasOpacityScale: Bool

    public init(maxStdDev: Float = 3.0, minAlpha: Float = 2.0 / 255.0, blurAmount: Float = 0.3, antialiasOpacityScale: Bool = false) {
        self.maxStdDev = maxStdDev
        self.minAlpha = minAlpha
        self.blurAmount = blurAmount
        self.antialiasOpacityScale = antialiasOpacityScale
    }

    /// Matches INRIA 3DGS / gsplat classic mode: 3σ footprint, 0.3 px²
    /// dilation, no opacity scale.
    public static let `default` = Self()
}
#endif

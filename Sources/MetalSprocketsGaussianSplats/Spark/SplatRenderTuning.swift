#if !arch(x86_64)
import Foundation

/// Runtime-tunable Spark render-quality parameters (from the blur-reduction
/// experiments). Applied as Metal function constants at pipeline build, so they
/// are compile-time constants inside the shader but selectable per pipeline.
public struct SplatRenderTuning: Equatable, Sendable {
    /// Gaussian cutoff radius in standard deviations. Smaller = tighter splats
    /// (fewer fragments, sharper), larger = softer/blurrier.
    public var maxStdDev: Float
    /// Splats whose alpha falls below this are skipped.
    public var minAlpha: Float
    /// Anti-aliasing covariance dilation in px² (0 disables). Higher inflates and
    /// blurs every splat.
    public var blurAmount: Float

    public init(maxStdDev: Float = 2.5, minAlpha: Float = 2.0 / 255.0, blurAmount: Float = 0.05) {
        self.maxStdDev = maxStdDev
        self.minAlpha = minAlpha
        self.blurAmount = blurAmount
    }

    /// Tuned defaults from the blur-reduction experiments (sharp, cheaper).
    public static let `default` = SplatRenderTuning()
}
#endif

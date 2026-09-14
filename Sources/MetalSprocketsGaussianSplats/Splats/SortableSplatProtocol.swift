import simd

/// A splat type that exposes its position so it can be depth-sorted.
public protocol SortableSplatProtocol: Equatable, Sendable {
    var floatPosition: SIMD3<Float> { get }

    /// Row index into the cloud's SH coefficient buffer. Dense clouds use the
    /// splat's own index (identity); indexed formats use a shared-palette row.
    var shIndex: UInt32 { get set }
}

public extension SortableSplatProtocol {
    var shIndex: UInt32 {
        get { 0 }
        set { _ = newValue }
    }
}

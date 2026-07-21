import simd

/// A splat type that exposes its position so it can be depth-sorted.
public protocol SortableSplatProtocol: Equatable, Sendable {
    var floatPosition: SIMD3<Float> { get }
}

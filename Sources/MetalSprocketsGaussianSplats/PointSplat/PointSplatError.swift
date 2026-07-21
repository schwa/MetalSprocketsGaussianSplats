/// Errors thrown by the PointSplat renderer, workload distributor, and
/// packed-cloud encoder (#100).
public enum PointSplatError: Error, Equatable {
    /// The device lacks 64-bit atomics (needs Apple9/A17/M3+ or Mac2).
    case unsupportedDevice
    case bufferAllocationFailed
    case textureAllocationFailed
    case commandEncodingFailed
    case functionNotFound(String)
    case splatCountExceedsMaximum(count: Int, maximum: Int)
    case emptyCloud
}

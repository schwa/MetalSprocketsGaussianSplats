#if os(iOS) || os(macOS)
import simd

/// Camera mode shared by both single and multi-cloud views
enum CameraMode: String, CaseIterable {
    case object = "Object"
    case room = "Room"
    case spatialScene = "Spatial Scene"

    var initialPosition: SIMD3<Float> {
        switch self {
        case .object:
            [0, 0, 5]
        case .room:
            [0, 0, 0]
        case .spatialScene:
            [0, 0, 0.2]
        }
    }
}

enum SplatContentMode {
    /// Single splat file - no sidebar, no add cloud
    case single
    /// Multi-cloud scene - sidebar with cloud list, add cloud enabled
    case multi
}
#endif

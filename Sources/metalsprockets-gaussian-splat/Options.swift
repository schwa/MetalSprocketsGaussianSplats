#if !arch(x86_64)
import ArgumentParser
import MetalSprocketsGaussianSplats

// Flags follow the splat-render spec (~/Projects/Scratch/splat-render/docs).
// ExtraOptions holds the flags that only this tool has.

struct Vector: ExpressibleByArgument {
    var values: [Double]

    init?(argument: String) {
        let parts = argument.split(separator: ",", omittingEmptySubsequences: false)
        let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == parts.count else {
            return nil
        }
        self.values = values
    }
}

enum ColorSpace: String, ExpressibleByArgument, CaseIterable {
    case srgb
    case linear
}

struct InputOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Read options from a JSON file. Flags on the command line take precedence over the file.", valueName: "file.json"))
    var config: String?

    @Option(name: [.customLong("spherical-harmonics-degree"), .customLong("sh-degree")], help: ArgumentHelp("Highest spherical-harmonics degree to use. 0 uses base color only. (default: everything in the file)", valueName: "0-3"))
    var sphericalHarmonicsDegree: Int?

    @Option(help: ArgumentHelp("Move the scene by this offset. (default: 0,0,0)", valueName: "x,y,z"))
    var modelPosition: Vector?
}

struct OutputOptions: ParsableArguments {
    @Option(name: [.customLong("output"), .customShort("o")], help: ArgumentHelp("Destination PNG. Omit to render without writing a file (useful with --statistics).", valueName: "file.png"))
    var output: String?

    @Option(name: [.customLong("width"), .customShort("w")], help: ArgumentHelp("Output width. (default: 1024)", valueName: "pixels"))
    var width: Int?

    // No short name: -h is --help.
    @Option(help: ArgumentHelp("Output height. (default: 768)", valueName: "pixels"))
    var height: Int?

    @Option(help: ArgumentHelp("Clear color, 0-1 per channel. (default: 0,0,0,1)", valueName: "r,g,b,a"))
    var background: Vector?

    @Flag(help: "Draw the render settings on top of the image.")
    var label = false
}

struct CameraOptions: ParsableArguments {
    @Option(name: [.customLong("camera-position"), .customLong("eye")], help: ArgumentHelp("Camera position. (default: 0,0,5)", valueName: "x,y,z"))
    var cameraPosition: Vector?

    @Option(name: [.customLong("camera-look-at"), .customLong("look-at")], help: ArgumentHelp("Point the camera looks at. (default: 0,0,0)", valueName: "x,y,z"))
    var cameraLookAt: Vector?

    @Option(name: [.customLong("camera-up"), .customLong("up")], help: ArgumentHelp("Camera up direction. (default: 0,1,0)", valueName: "x,y,z"))
    var cameraUp: Vector?

    @Option(help: ArgumentHelp("Camera orientation as a quaternion or a 3x3 matrix. Use instead of --camera-look-at and --camera-up.", valueName: "x,y,z,w | m00,...,m22"))
    var cameraRotation: Vector?

    @Option(help: ArgumentHelp("Camera-to-world matrix, 16 column-major values. This is the whole camera. Do not combine it with any other --camera-* option.", valueName: "m00,...,m33"))
    var cameraMatrix: Vector?
}

struct ProjectionOptions: ParsableArguments {
    @Option(name: [.customLong("projection-fov"), .customLong("fov"), .customShort("f")], help: ArgumentHelp("Vertical field of view. (default: 60)", valueName: "degrees"))
    var projectionFov: Double?

    @Option(name: [.customLong("projection-near"), .customLong("near")], help: ArgumentHelp("Near clipping plane. (default: 0.1)", valueName: "distance"))
    var projectionNear: Double?

    @Option(name: [.customLong("projection-far"), .customLong("far")], help: ArgumentHelp("Far clipping plane. (default: 100)", valueName: "distance"))
    var projectionFar: Double?
}

struct QualityOptions: ParsableArguments {
    @Flag(inversion: .prefixedNo, help: "Add the INRIA 0.3 px low-pass dilation to each splat's 2D covariance. (default: on)")
    var dilation: Bool?

    @Option(help: ArgumentHelp("How to read splat colors. srgb writes them out as-is. linear converts sRGB to linear in the shader. (default: srgb)", valueName: "srgb|linear"))
    var colorSpace: ColorSpace?

    @Option(help: ArgumentHelp("Render smaller by this factor, then upscale to --width x --height with MetalFX. Must be greater than 1. Spark renderer only.", valueName: "factor"))
    var upscaleFactor: Double?
}

struct TimingOptions: ParsableArguments {
    @Option(name: [.customLong("statistics"), .customLong("stats")], help: ArgumentHelp("Report wall time, GPU time, and the time for each pass. A bare --statistics means text.", valueName: "text|json"))
    var statistics: StatisticsFormat?

    @Option(name: [.customLong("warmup-frames"), .customLong("warmup")], help: ArgumentHelp("Frames to render and discard before measuring. (default: 0)", valueName: "count"))
    var warmupFrames: Int?

    @Option(name: [.customLong("measured-frames"), .customLong("frames")], help: ArgumentHelp("Frames to measure. With more than one frame, the report shows medians. (default: 1)", valueName: "count"))
    var measuredFrames: Int?
}

struct ExtraOptions: ParsableArguments {
    @Option(help: "Renderer to use. (default: spark)")
    var renderer: RendererKind?

    @Option(help: "Point renderer supersampling factor. (default: 2)")
    var supersampling: Int?

    @Option(help: "Point renderer points per thread. (default: 4)")
    var pointsPerThread: Int?

    @Option(help: "GPU sort depth-key precision: 16 or 32 bits. (default: 16)")
    var sortPrecision: SplatSortPrecision?

    @Flag(help: "Enable Metal frame capture for debugging in Xcode.")
    var capture = false

    @Flag(help: "Reveal the output file in Finder after rendering.")
    var reveal = false
}
#endif

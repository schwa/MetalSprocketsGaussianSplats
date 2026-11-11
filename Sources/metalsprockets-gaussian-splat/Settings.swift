#if !arch(x86_64)
import Foundation
import MetalSprocketsGaussianSplats
import simd

// Exit codes from the splat-render spec: 64 usage, 65 unreadable scene, 1 render failure.
struct UsageError: Error {
    var message: String
    init(_ message: String) {
        self.message = message
    }
}

struct SceneError: Error {
    var message: String
    init(_ message: String) {
        self.message = message
    }
}

struct RenderError: Error {
    var message: String
    init(_ message: String) {
        self.message = message
    }
}

/// The options after the config file merge, with defaults filled in.
struct Settings {
    var scene: String
    var sphericalHarmonicsDegree: Int?
    var modelPosition: [Double]
    var output: String?
    var width: Int
    var height: Int
    var background: [Double]
    var label: Bool
    var cameraPosition: [Double]?
    var cameraLookAt: [Double]?
    var cameraUp: [Double]?
    var cameraRotation: [Double]?
    var cameraMatrix: [Double]?
    var projectionFov: Double
    var projectionNear: Double
    var projectionFar: Double
    var dilation: Bool
    var colorSpace: ColorSpace
    var upscaleFactor: Double?
    var statistics: StatisticsFormat?
    var warmupFrames: Int
    var measuredFrames: Int
    var renderer: RendererKind
    var supersampling: Int
    var pointsPerThread: Int
    var sortPrecision: SplatSortPrecision
    var capture: Bool
    var reveal: Bool

    init(command: GaussianSplatRenderer) throws {
        let config = try command.input.config.map(ConfigFile.init(path:))
        guard let scene = try command.scene ?? config?.path("scene") else {
            throw UsageError("missing scene")
        }
        self.scene = scene
        sphericalHarmonicsDegree = try command.input.sphericalHarmonicsDegree ?? config?.int("sphericalHarmonicsDegree")
        modelPosition = try command.input.modelPosition?.values ?? config?.numbers("modelPosition") ?? [0, 0, 0]
        output = try command.output.output ?? config?.path("output")
        width = try command.output.width ?? config?.int("width") ?? 1_024
        height = try command.output.height ?? config?.int("height") ?? 768
        background = try command.output.background?.values ?? config?.numbers("background") ?? [0, 0, 0, 1]
        label = try command.output.label || (config?.bool("label") ?? false)
        cameraPosition = try command.camera.cameraPosition?.values ?? config?.numbers("cameraPosition")
        cameraLookAt = try command.camera.cameraLookAt?.values ?? config?.numbers("cameraLookAt")
        cameraUp = try command.camera.cameraUp?.values ?? config?.numbers("cameraUp")
        cameraRotation = try command.camera.cameraRotation?.values ?? config?.numbers("cameraRotation")
        cameraMatrix = try command.camera.cameraMatrix?.values ?? config?.numbers("cameraMatrix")
        projectionFov = try command.projection.projectionFov ?? config?.double("projectionFov") ?? 60
        projectionNear = try command.projection.projectionNear ?? config?.double("projectionNear") ?? 0.1
        projectionFar = try command.projection.projectionFar ?? config?.double("projectionFar") ?? 100
        dilation = try command.quality.dilation ?? config?.bool("dilation") ?? true
        colorSpace = try command.quality.colorSpace ?? config?.enumeration("colorSpace") ?? .srgb
        upscaleFactor = try command.quality.upscaleFactor ?? config?.double("upscaleFactor")
        statistics = try command.timing.statistics ?? config?.enumeration("statistics")
        warmupFrames = try command.timing.warmupFrames ?? config?.int("warmupFrames") ?? 0
        measuredFrames = try command.timing.measuredFrames ?? config?.int("measuredFrames") ?? 1
        renderer = try command.extra.renderer ?? config?.enumeration("renderer") ?? .spark
        supersampling = try command.extra.supersampling ?? config?.int("supersampling") ?? 2
        pointsPerThread = try command.extra.pointsPerThread ?? config?.int("pointsPerThread") ?? 4
        let sortBits = try config?.int("sortPrecision")
        if let sortBits, SplatSortPrecision(rawValue: sortBits) == nil {
            throw UsageError("--sort-precision must be 16 or 32")
        }
        sortPrecision = command.extra.sortPrecision ?? sortBits.flatMap(SplatSortPrecision.init(rawValue:)) ?? .float16
        capture = try command.extra.capture || (config?.bool("capture") ?? false)
        reveal = try command.extra.reveal || (config?.bool("reveal") ?? false)
        try validate()
    }

    private func validate() throws {
        try check(modelPosition, "--model-position", counts: [3])
        try check(background, "--background", counts: [4])
        try check(cameraPosition, "--camera-position", counts: [3])
        try check(cameraLookAt, "--camera-look-at", counts: [3])
        try check(cameraUp, "--camera-up", counts: [3])
        try check(cameraRotation, "--camera-rotation", counts: [4, 9])
        try check(cameraMatrix, "--camera-matrix", counts: [16])
        if width < 1 || height < 1 {
            throw UsageError("--width and --height must be at least 1")
        }
        if warmupFrames < 0 {
            throw UsageError("--warmup-frames must not be negative")
        }
        if measuredFrames < 1 {
            throw UsageError("--measured-frames must be at least 1")
        }
        if let upscaleFactor, upscaleFactor <= 1 {
            throw UsageError("--upscale-factor must be greater than 1")
        }
        if upscaleFactor != nil, renderer != .spark {
            throw UsageError("--upscale-factor needs --renderer spark")
        }
        if cameraMatrix != nil, [cameraPosition, cameraLookAt, cameraUp, cameraRotation].contains(where: { $0 != nil }) {
            throw UsageError("--camera-matrix cannot be combined with other --camera-* options")
        }
        if cameraRotation != nil, cameraLookAt != nil || cameraUp != nil {
            throw UsageError("--camera-rotation cannot be combined with --camera-look-at or --camera-up")
        }
        if cameraMatrix == nil, cameraRotation == nil, (cameraPosition ?? [0, 0, 5]) == (cameraLookAt ?? [0, 0, 0]) {
            throw UsageError("--camera-position and --camera-look-at are the same point")
        }
        if let sphericalHarmonicsDegree, !(0...3).contains(sphericalHarmonicsDegree) {
            throw UsageError("--spherical-harmonics-degree must be 0, 1, 2, or 3")
        }
        if !(projectionNear > 0 && projectionNear < projectionFar) {
            throw UsageError("--projection-near must be greater than 0 and less than --projection-far")
        }
        if !(projectionFov > 0 && projectionFov < 180) {
            throw UsageError("--projection-fov must be greater than 0 and less than 180")
        }
        if supersampling < 1 || pointsPerThread < 1 {
            throw UsageError("--supersampling and --points-per-thread must be at least 1")
        }
    }

    private func check(_ values: [Double]?, _ flag: String, counts: [Int]) throws {
        guard let values, !counts.contains(values.count) else {
            return
        }
        let expected = counts.map(String.init).joined(separator: " or ")
        throw UsageError("\(flag) needs \(expected) comma-separated numbers")
    }

    // MARK: - Derived values

    /// Camera-to-world. The camera looks down -Z with +Y up.
    func cameraToWorld() throws -> simd_float4x4 {
        if let matrix = cameraMatrix?.map(Float.init) {
            return simd_float4x4(
                SIMD4(matrix[0], matrix[1], matrix[2], matrix[3]),
                SIMD4(matrix[4], matrix[5], matrix[6], matrix[7]),
                SIMD4(matrix[8], matrix[9], matrix[10], matrix[11]),
                SIMD4(matrix[12], matrix[13], matrix[14], matrix[15])
            )
        }
        let position = vector3(cameraPosition ?? [0, 0, 5])
        let rotation: simd_float3x3
        if let values = cameraRotation?.map(Float.init) {
            if values.count == 4 {
                rotation = simd_float3x3(simd_normalize(simd_quatf(ix: values[0], iy: values[1], iz: values[2], r: values[3])))
            } else {
                rotation = simd_float3x3(
                    SIMD3(values[0], values[1], values[2]),
                    SIMD3(values[3], values[4], values[5]),
                    SIMD3(values[6], values[7], values[8])
                )
            }
        } else {
            let target = vector3(cameraLookAt ?? [0, 0, 0])
            let up = vector3(cameraUp ?? [0, 1, 0])
            let zAxis = simd_normalize(position - target)
            let xAxis = simd_cross(up, zAxis)
            guard simd_length(xAxis) > 1e-6 else {
                throw UsageError("--camera-up must not be zero or parallel to the view direction")
            }
            let xNormalized = simd_normalize(xAxis)
            rotation = simd_float3x3(xNormalized, simd_cross(zAxis, xNormalized), zAxis)
        }
        return simd_float4x4(
            SIMD4(rotation.columns.0, 0),
            SIMD4(rotation.columns.1, 0),
            SIMD4(rotation.columns.2, 0),
            SIMD4(position, 1)
        )
    }

    func modelMatrix() -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(vector3(modelPosition), 1)
        return matrix
    }

    var backgroundColor: SIMD4<Float> {
        SIMD4(Float(background[0]), Float(background[1]), Float(background[2]), Float(background[3]))
    }

    private func vector3(_ values: [Double]) -> SIMD3<Float> {
        SIMD3(Float(values[0]), Float(values[1]), Float(values[2]))
    }
}

// MARK: - Config file

// NSNumber is needed to tell JSON booleans from numbers.
// swiftlint:disable legacy_objc_type

/// `--config` JSON. Each key is a long flag name in camelCase.
struct ConfigFile {
    static let keys: Set<String> = [
        "scene", "sphericalHarmonicsDegree", "modelPosition", "output", "width", "height", "background", "label",
        "cameraPosition", "cameraLookAt", "cameraUp", "cameraRotation", "cameraMatrix",
        "projectionFov", "projectionNear", "projectionFar", "dilation", "colorSpace", "upscaleFactor",
        "statistics", "warmupFrames", "measuredFrames",
        "renderer", "supersampling", "pointsPerThread", "sortPrecision", "capture", "reveal"
    ]

    let file: String
    let directory: URL
    let values: [String: Any]

    init(path: String) throws {
        file = path
        let url = URL(fileURLWithPath: path)
        directory = url.deletingLastPathComponent()
        let object: Any
        do {
            let data = try Data(contentsOf: url)
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageError("cannot read config \(path): \(error.localizedDescription)")
        }
        guard let values = object as? [String: Any] else {
            throw UsageError("cannot read config \(path): the top level is not a JSON object")
        }
        if let unknown = values.keys.sorted().first(where: { !Self.keys.contains($0) }) {
            throw UsageError("unknown key '\(unknown)' in \(path)")
        }
        self.values = values
    }

    private func typeError(_ key: String, _ expected: String) -> UsageError {
        UsageError("cannot read config \(file): '\(key)' must be \(expected)")
    }

    /// Relative paths are relative to the config file.
    func path(_ key: String) throws -> String? {
        guard let value = values[key] else {
            return nil
        }
        guard let string = value as? String else {
            throw typeError(key, "a string")
        }
        return string.hasPrefix("/") ? string : directory.appendingPathComponent(string).path
    }

    private func number(_ key: String, _ value: Any) throws -> NSNumber {
        // JSONSerialization returns booleans as NSNumber too.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw typeError(key, "a number")
        }
        return number
    }

    func double(_ key: String) throws -> Double? {
        try values[key].map { try number(key, $0).doubleValue }
    }

    func int(_ key: String) throws -> Int? {
        guard let value = values[key] else {
            return nil
        }
        let double = try number(key, value).doubleValue
        guard double.rounded() == double, let int = Int(exactly: double) else {
            throw typeError(key, "an integer")
        }
        return int
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else {
            return nil
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw typeError(key, "a boolean")
        }
        return number.boolValue
    }

    func numbers(_ key: String) throws -> [Double]? {
        guard let value = values[key] else {
            return nil
        }
        guard let array = value as? [Any] else {
            throw typeError(key, "an array of numbers")
        }
        return try array.map { try number(key, $0).doubleValue }
    }

    func enumeration<T: RawRepresentable & CaseIterable>(_ key: String) throws -> T? where T.RawValue == String {
        guard let value = values[key] else {
            return nil
        }
        guard let string = value as? String, let result = T(rawValue: string) else {
            throw typeError(key, T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or "))
        }
        return result
    }
}
// swiftlint:enable legacy_objc_type
#endif

import AppKit
@preconcurrency import ArgumentParser
import Foundation
import GeometryLite3D
import ImageIO
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import simd
import Splats
import SwiftUI

@main
struct GaussianSplatRenderer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gsplat-render",
        abstract: "Render Gaussian splat files to PNG images"
    )

    @Option(help: "Background color in RGBA format (e.g., 0,0,0,1 for black)")
    var background: String = "0,0,0,1"

    @Option(help: "Width of the output image")
    var width: Int = 1_024

    @Option(help: "Height of the output image")
    var height: Int = 768

    @Option(help: "Output PNG file path")
    var output: String = "output.png"

    @Option(help: "Model position in x,y,z format (e.g., 0,0,0)")
    var modelPosition: String?

    @Option(help: "Camera position in x,y,z format (e.g., 0,0,1.5)")
    var cameraPosition: String?

    @Option(help: "Camera look-at target in x,y,z format (e.g., 0,0,0)")
    var cameraLookat: String?

    @Option(help: "Camera rotation as quaternion (x,y,z,w) or 3x3 matrix (9 values comma-separated)")
    var cameraRotation: String?

    @Option(help: "Projection field of view in degrees")
    var projectionFov: Double?

    @Option(help: "Camera near clipping plane")
    var near: Float = 0.1

    @Option(help: "Camera far clipping plane")
    var far: Float = 100.0

    @Option(help: "Path to splat file (.splat, .ply, .spz) to render")
    var splat: String?

    @Option(help: "Path to JSON configuration file")
    var config: String?

    @Flag(help: "Enable Metal frame capture for debugging in Xcode")
    var capture: Bool = false

    @Option(help: "Renderer to use: antimatter15 or spark")
    var renderer: String = "antimatter15"

    @Flag(help: "Convert sRGB to linear in fragment shader (for Spark renderer)")
    var srgbToLinear: Bool = false

    @Flag(help: "Render settings label on top of the image")
    var label: Bool = false

    @Option(help: "Override SH degree (0=off, 1-3=use specified degree)")
    var shDegree: Int?

    @Flag(help: "Reveal output file in Finder after rendering")
    var reveal: Bool = false

    @Option(help: "Export splat data to CSV file")
    var dumpCsv: String?

    mutating func run() async throws {
        try await _run()
    }

    @MainActor
    mutating func _run() throws {
        #if !arch(x86_64)
        let renderConfig = try loadConfig()
        let device = _MTLCreateSystemDefaultDevice()
        let loadResult = try loadSplats(from: renderConfig.splat)

        // Print splat info
        print("Loaded \(loadResult.splats.count) splats, SH degree: \(loadResult.shDegree), SH coefficients: \(loadResult.shCoefficients.count)")

        // Export to CSV if requested
        if let csvPath = dumpCsv {
            try exportToCSV(loadResult: loadResult, path: csvPath)
            print("Exported \(loadResult.splats.count) splats to \(csvPath)")
            return
        }

        let modelMatrix = try parseModelMatrix(from: renderConfig)
        let cameraMatrix = try parseCameraMatrix(from: renderConfig)
        let useSparkRenderer = (renderConfig.renderer ?? "antimatter15").lowercased() == "spark"
        let useSrgbToLinear = renderConfig.srgbToLinear ?? false

        let (antimatter15GPUSplatCloud, sparkGPUSplatCloud, shCoefficientsBuffer, effectiveSHDegree) = try createGPUSplatClouds(
            loadResult: loadResult,
            device: device,
            useSparkRenderer: useSparkRenderer,
            modelMatrix: modelMatrix,
            cameraMatrix: cameraMatrix
        )

        print("Effective SH degree: \(effectiveSHDegree), SH buffer: \(shCoefficientsBuffer != nil ? "yes" : "no")")

        let size = CGSize(width: renderConfig.width, height: renderConfig.height)
        let projection = try createProjection(from: renderConfig)
        let bgColor = renderConfig.getBackground()

        let (rendering, splatCount) = try performRender(
            renderConfig: renderConfig,
            size: size,
            projection: projection,
            bgColor: bgColor,
            useSparkRenderer: useSparkRenderer,
            useSrgbToLinear: useSrgbToLinear,
            modelMatrix: modelMatrix,
            cameraMatrix: cameraMatrix,
            antimatter15GPUSplatCloud: antimatter15GPUSplatCloud,
            sparkGPUSplatCloud: sparkGPUSplatCloud,
            shCoefficientsBuffer: shCoefficientsBuffer,
            effectiveSHDegree: effectiveSHDegree
        )

        var cgImage = try rendering.cgImage
        if label {
            cgImage = addLabel(to: cgImage, renderConfig: renderConfig, splatCount: splatCount, useSparkRenderer: useSparkRenderer, useSrgbToLinear: useSrgbToLinear, effectiveSHDegree: effectiveSHDegree)
        }

        try saveOutput(cgImage: cgImage, to: renderConfig.output, reveal: reveal)
        #else
        throw ValidationError("This tool requires Apple Silicon (ARM64) on macOS")
        #endif
    }

    // MARK: - Config Loading

    mutating func loadConfig() throws -> RenderConfig {
        var renderConfig: RenderConfig
        if let configPath = config {
            renderConfig = try RenderConfig.load(from: configPath)
            try applyCliOverrides(to: &renderConfig)
        } else {
            guard let splatPath = splat else {
                throw ValidationError("Must specify a splat file with --splat or use --config")
            }
            renderConfig = try buildConfigFromCli(splatPath: splatPath)
        }

        let splatPath = renderConfig.splat
        guard FileManager.default.fileExists(atPath: splatPath) else {
            throw ValidationError("Splat file not found: \(splatPath)")
        }

        return renderConfig
    }

    mutating func applyCliOverrides(to renderConfig: inout RenderConfig) throws {
        if background != "0,0,0,1" {
            let bgComponents = try parseRGBA(background)
            renderConfig.background = [bgComponents.x, bgComponents.y, bgComponents.z, bgComponents.w]
        }
        if width != 1_024 { renderConfig.width = width }
        if height != 768 { renderConfig.height = height }
        if output != "output.png" { renderConfig.output = output }
        if let pos = modelPosition {
            let v = try parseXYZ(pos)
            renderConfig.modelPosition = [v.x, v.y, v.z]
        }
        if let pos = cameraPosition {
            let v = try parseXYZ(pos)
            renderConfig.cameraPosition = [v.x, v.y, v.z]
        }
        if let lookat = cameraLookat {
            let v = try parseXYZ(lookat)
            renderConfig.cameraLookat = [v.x, v.y, v.z]
        }
        if let rot = cameraRotation {
            renderConfig.cameraRotation = rot.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        }
        if let fov = projectionFov { renderConfig.projectionFov = fov }
        if near != 0.1 { renderConfig.near = near }
        if far != 100.0 { renderConfig.far = far }
        if let s = splat { renderConfig.splat = s }
        if renderer != "antimatter15" { renderConfig.renderer = renderer }
        if srgbToLinear { renderConfig.srgbToLinear = true }
    }

    func buildConfigFromCli(splatPath: String) throws -> RenderConfig {
        let bgComponents = try parseRGBA(background)
        return RenderConfig(
            background: [bgComponents.x, bgComponents.y, bgComponents.z, bgComponents.w],
            width: width,
            height: height,
            output: output,
            modelPosition: try modelPosition.map { let v = try parseXYZ($0); return [v.x, v.y, v.z] },
            cameraPosition: try cameraPosition.map { let v = try parseXYZ($0); return [v.x, v.y, v.z] },
            cameraLookat: try cameraLookat.map { let v = try parseXYZ($0); return [v.x, v.y, v.z] },
            cameraRotation: cameraRotation?.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) },
            projectionFov: projectionFov,
            near: near,
            far: far,
            splat: splatPath,
            renderer: renderer,
            srgbToLinear: srgbToLinear
        )
    }

    // MARK: - Splat Loading

    /// Result of loading splats, including optional SH data
    struct SplatLoadResult {
        let splats: [GenericSplat]
        let shCoefficients: [Float]
        let shDegree: UInt8
    }

    #if !arch(x86_64)
    func loadSplats(from splatPath: String) throws -> SplatLoadResult {
        let splatURL = URL(fileURLWithPath: splatPath)
        let fileExtension = splatURL.pathExtension.lowercased()

        var splats: [GenericSplat] = []
        var shCoefficients: [Float] = []
        var detectedSHDegree: UInt8 = 0

        switch fileExtension {
        case "spz":
            let reader = try Splats.SPZReader(url: splatURL)
            detectedSHDegree = reader.shDegree
            let floatsPerSplat = Self.shFloatsPerSplat(degree: detectedSHDegree)
            if floatsPerSplat > 0 {
                shCoefficients.reserveCapacity(reader.splatCount * floatsPerSplat)
            }
            try reader.read { _, extendedSplat in
                splats.append(extendedSplat.genericSplat)
                if let sh = extendedSplat.sphericalHarmonics {
                    for coeff in sh {
                        shCoefficients.append(contentsOf: coeff)
                    }
                }
            }

        case "ply":
            let reader = try PLYSplatReader(url: splatURL)
            detectedSHDegree = reader.shDegree
            let floatsPerSplat = Self.shFloatsPerSplat(degree: detectedSHDegree)
            if floatsPerSplat > 0 {
                shCoefficients.reserveCapacity(reader.splatCount * floatsPerSplat)
            }
            try reader.read { _, extendedSplat in
                splats.append(extendedSplat.genericSplat)
                if let sh = extendedSplat.sphericalHarmonics {
                    for coeff in sh {
                        shCoefficients.append(contentsOf: coeff)
                    }
                }
            }

        case "splat":
            let reader = try Antimatter15Reader(url: splatURL)
            try reader.read { _, extendedSplat in
                splats.append(extendedSplat.genericSplat)
            }

        case "sog":
            let reader = try SOGReaderCPU(url: splatURL)
            detectedSHDegree = UInt8(reader.shDegree)
            let floatsPerSplat = Self.shFloatsPerSplat(degree: detectedSHDegree)
            if floatsPerSplat > 0 {
                shCoefficients.reserveCapacity(reader.splatCount * floatsPerSplat)
            }
            try reader.read { _, extendedSplat in
                splats.append(extendedSplat.genericSplat)
                if let sh = extendedSplat.sphericalHarmonics {
                    for coeff in sh {
                        shCoefficients.append(contentsOf: coeff)
                    }
                }
            }

        default:
            throw ValidationError("Unsupported file format: .\(fileExtension)")
        }

        // Debug: print SH coefficients for first few splats
        if detectedSHDegree > 0, !shCoefficients.isEmpty {
            let floatsPerSplat = Self.shFloatsPerSplat(degree: detectedSHDegree)
            print("SH Debug (\(fileExtension)): degree=\(detectedSHDegree), floatsPerSplat=\(floatsPerSplat)")
            for splatIdx in [0, 1, 100, 1_000] {
                if splatIdx >= splats.count { continue }
                let baseOffset = splatIdx * floatsPerSplat
                print("  Splat \(splatIdx) first 3 coeffs:")
                for i in 0..<min(3, floatsPerSplat / 3) {
                    let r = shCoefficients[baseOffset + i * 3]
                    let g = shCoefficients[baseOffset + i * 3 + 1]
                    let b = shCoefficients[baseOffset + i * 3 + 2]
                    print("    [\(i)]: R=\(String(format: "%+.4f", r)), G=\(String(format: "%+.4f", g)), B=\(String(format: "%+.4f", b))")
                }
            }
        }

        return SplatLoadResult(splats: splats, shCoefficients: shCoefficients, shDegree: detectedSHDegree)
    }

    /// Returns the number of floats per splat for a given SH degree
    private static func shFloatsPerSplat(degree: UInt8) -> Int {
        switch degree {
        case 0: return 0
        case 1: return 3 * 3   // 3 basis functions * 3 channels (RGB)
        case 2: return 8 * 3   // 8 basis functions * 3 channels
        case 3: return 15 * 3  // 15 basis functions * 3 channels
        default: return 0
        }
    }

    // MARK: - CSV Export

    func exportToCSV(loadResult: SplatLoadResult, path: String) throws {
        var csv = "index,pos_x,pos_y,pos_z,scale_x,scale_y,scale_z,rot_x,rot_y,rot_z,rot_w,r,g,b,a"

        // Add SH coefficient headers
        let floatsPerSplat = Self.shFloatsPerSplat(degree: loadResult.shDegree)
        let numCoeffs = floatsPerSplat / 3
        for i in 0..<numCoeffs {
            csv += ",sh\(i)_r,sh\(i)_g,sh\(i)_b"
        }
        csv += "\n"

        for (index, splat) in loadResult.splats.enumerated() {
            var row = "\(index)"
            row += ",\(splat.position.x),\(splat.position.y),\(splat.position.z)"
            row += ",\(splat.scale.x),\(splat.scale.y),\(splat.scale.z)"
            row += ",\(splat.rotation.x),\(splat.rotation.y),\(splat.rotation.z),\(splat.rotation.w)"
            row += ",\(splat.color.x),\(splat.color.y),\(splat.color.z),\(splat.color.w)"

            // Add SH coefficients
            if floatsPerSplat > 0, !loadResult.shCoefficients.isEmpty {
                let baseOffset = index * floatsPerSplat
                for i in 0..<numCoeffs {
                    let r = loadResult.shCoefficients[baseOffset + i * 3]
                    let g = loadResult.shCoefficients[baseOffset + i * 3 + 1]
                    let b = loadResult.shCoefficients[baseOffset + i * 3 + 2]
                    row += ",\(r),\(g),\(b)"
                }
            }

            csv += row + "\n"
        }

        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Splat Cloud Creation

    func createGPUSplatClouds(
        loadResult: SplatLoadResult,
        device: MTLDevice,
        useSparkRenderer: Bool,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4
    ) throws -> (GPUSplatCloud<Antimatter15GPUSplat>?, GPUSplatCloud<SparkSplat>?, TypedMTLBuffer<Float>?, UInt8) {
        // Apply --sh-degree override if specified
        let effectiveSHDegree: UInt8
        if let override = shDegree {
            effectiveSHDegree = UInt8(override)
        } else {
            effectiveSHDegree = loadResult.shDegree
        }

        // Create SH buffer if we have SH data and it's enabled
        var shCoefficientsBuffer: TypedMTLBuffer<Float>?
        if !loadResult.shCoefficients.isEmpty, effectiveSHDegree > 0 {
            shCoefficientsBuffer = try device.makeTypedBuffer(values: loadResult.shCoefficients, options: [])
        }

        if useSparkRenderer {
            let gpuSplats = loadResult.splats.map { SparkSplat($0) }
            let splatBuffer = try device.makeTypedBuffer(values: gpuSplats, options: [])
            var sparkGPUSplatCloud = try GPUSplatCloud<SparkSplat>(
                device: device,
                splats: splatBuffer,
                cameraMatrix: cameraMatrix,
                modelMatrix: modelMatrix
            )
            // Attach SH data to the cloud
            if let shBuffer = shCoefficientsBuffer {
                sparkGPUSplatCloud.shCoefficients = shBuffer
                sparkGPUSplatCloud.shDegree = effectiveSHDegree
            }
            return (nil, sparkGPUSplatCloud, shCoefficientsBuffer, effectiveSHDegree)
        }
        let gpuSplats = loadResult.splats.map { Antimatter15GPUSplat($0) }
        let splatBuffer = try device.makeTypedBuffer(values: gpuSplats, options: [])
        let antimatter15GPUSplatCloud = try GPUSplatCloud<Antimatter15GPUSplat>(
            device: device,
            splats: splatBuffer,
            cameraMatrix: cameraMatrix,
            modelMatrix: modelMatrix
        )
        return (antimatter15GPUSplatCloud, nil, shCoefficientsBuffer, effectiveSHDegree)
    }

    // MARK: - Rendering

    @MainActor
    func performRender(
        renderConfig _: RenderConfig,
        size: CGSize,
        projection: any ProjectionProtocol,
        bgColor: SIMD4<Float>,
        useSparkRenderer: Bool,
        useSrgbToLinear: Bool,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        antimatter15GPUSplatCloud: GPUSplatCloud<Antimatter15GPUSplat>?,
        sparkGPUSplatCloud: GPUSplatCloud<SparkSplat>?,
        shCoefficientsBuffer _: TypedMTLBuffer<Float>?,
        effectiveSHDegree _: UInt8
    ) throws -> (OffscreenRenderer.Rendering, Int) {
        let renderer = try OffscreenRenderer(size: size)
        renderer.renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bgColor.x),
            green: Double(bgColor.y),
            blue: Double(bgColor.z),
            alpha: Double(bgColor.w)
        )

        let captureManager = MTLCaptureManager.shared()
        let splatCount: Int
        let rendering: OffscreenRenderer.Rendering

        if useSparkRenderer {
            guard let cloud = sparkGPUSplatCloud else {
                throw NSError(domain: "gsplat-render", code: 1, userInfo: [NSLocalizedDescriptionKey: "Spark splat cloud is nil"])
            }
            splatCount = cloud.count
            let renderContent = try RenderPass {
                let aspectRatio = Float(size.width) / Float(size.height)
                let projectionMatrix = projection.projectionMatrix(aspectRatio: aspectRatio)
                try SparkSplatRenderPipeline(
                    splatCloud: cloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: SIMD2<Float>(Float(size.width), Float(size.height)),
                    convertSRGBToLinear: useSrgbToLinear
                )
            }
            rendering = try captureManager.with(enabled: capture) {
                try renderer.render(renderContent)
            }
        } else {
            guard let cloud = antimatter15GPUSplatCloud else {
                throw NSError(domain: "gsplat-render", code: 1, userInfo: [NSLocalizedDescriptionKey: "Antimatter15 splat cloud is nil"])
            }
            splatCount = cloud.count
            let renderContent = try RenderPass {
                let aspectRatio = Float(size.width) / Float(size.height)
                let projectionMatrix = projection.projectionMatrix(aspectRatio: aspectRatio)
                try Antimatter15SplatRenderPipeline(
                    splatCloud: cloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: SIMD2<Float>(Float(size.width), Float(size.height)),
                    debugMode: .off
                )
            }
            rendering = try captureManager.with(enabled: capture) {
                try renderer.render(renderContent)
            }
        }

        return (rendering, splatCount)
    }

    // MARK: - Label Overlay

    @MainActor
    func addLabel(to cgImage: CGImage, renderConfig: RenderConfig, splatCount: Int, useSparkRenderer: Bool, useSrgbToLinear: Bool, effectiveSHDegree: UInt8) -> CGImage {
        let fovStr = renderConfig.projectionFov.map { String(format: "%.1f°", $0) } ?? "60°"
        let camPos = renderConfig.getCameraPosition() ?? SIMD3<Float>(0, 0, 1.5)
        let modelPos = renderConfig.getModelPosition() ?? SIMD3<Float>(0, 0, 0)

        let shInfo = useSparkRenderer ? " | SH: \(effectiveSHDegree > 0 ? "deg \(effectiveSHDegree)" : "off")" : ""
        let labelText = """
        Renderer: \(useSparkRenderer ? "Spark" : "Antimatter15") | sRGB→Linear: \(useSrgbToLinear)\(shInfo)
        Size: \(renderConfig.width)x\(renderConfig.height) | FOV: \(fovStr)
        Splats: \(splatCount) | Near/Far: \(renderConfig.near)/\(renderConfig.far)
        Camera: (\(String(format: "%.2f", camPos.x)), \(String(format: "%.2f", camPos.y)), \(String(format: "%.2f", camPos.z)))
        Model: (\(String(format: "%.2f", modelPos.x)), \(String(format: "%.2f", modelPos.y)), \(String(format: "%.2f", modelPos.z)))
        """

        let labelView = ZStack(alignment: .bottomLeading) {
            Image(decorative: cgImage, scale: 1.0)
            Text(labelText)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .padding(8)
                .background(Color.black.opacity(0.7))
                .cornerRadius(4)
                .padding(10)
        }

        let renderer = ImageRenderer(content: labelView)
        renderer.scale = 1.0
        return renderer.cgImage ?? cgImage
    }

    // MARK: - Output Saving

    func saveOutput(cgImage: CGImage, to outputPath: String, reveal: Bool) throws {
        var finalPath = outputPath
        if !finalPath.hasPrefix("/") {
            finalPath = FileManager.default.currentDirectoryPath + "/" + finalPath
        }

        let outputURL = URL(fileURLWithPath: finalPath)
        if let parentDir = outputURL.deletingLastPathComponent().path as String? {
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw ValidationError("Failed to create image destination")
        }

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw ValidationError("Failed to write image to \(outputPath)")
        }

        if reveal {
            NSWorkspace.shared.selectFile(finalPath, inFileViewerRootedAtPath: "")
        }
    }
    #endif

    // MARK: - Helper Functions

    func parseRGBA(_ string: String) throws -> SIMD4<Float> {
        let components = string.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count == 4 else {
            throw ValidationError("Background color must be in RGBA format (4 comma-separated values)")
        }
        return SIMD4<Float>(components[0], components[1], components[2], components[3])
    }

    func parseXYZ(_ string: String) throws -> SIMD3<Float> {
        let components = string.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count == 3 else {
            throw ValidationError("Position must be in x,y,z format (3 comma-separated values)")
        }
        return SIMD3<Float>(components[0], components[1], components[2])
    }

    func parseModelMatrix(from config: RenderConfig) throws -> simd_float4x4 {
        if let position = config.getModelPosition() {
            return simd_float4x4(translation: position)
        }
        return .identity
    }

    func parseCameraMatrix(from config: RenderConfig) throws -> simd_float4x4 {
        // Priority: rotation > lookat > position
        if let rotation = config.getCameraRotation() {
            return try parseCameraRotationMatrix(rotation, config: config)
        }

        if let target = config.getCameraLookat() {
            let position = config.getCameraPosition() ?? SIMD3<Float>(0, 0, 1.5)
            return LookAt(position: position, target: target, up: SIMD3<Float>(0, 1, 0)).cameraMatrix
        }

        if let position = config.getCameraPosition() {
            // Simple translation
            return simd_float4x4(translation: position)
        }

        // Default camera at (0, 0, 1.5) looking at origin
        return LookAt(position: SIMD3<Float>(0, 0, 1.5), target: SIMD3<Float>(0, 0, 0), up: SIMD3<Float>(0, 1, 0)).cameraMatrix
    }

    func parseCameraRotationMatrix(_ components: [Float], config: RenderConfig) throws -> simd_float4x4 {
        if components.count == 4 {
            // Quaternion (x, y, z, w)
            let quat = simd_quatf(ix: components[0], iy: components[1], iz: components[2], r: components[3])
            let rotationMatrix = simd_float4x4(quat)

            // Apply position if specified
            if let position = config.getCameraPosition() {
                var matrix = rotationMatrix
                matrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
                return matrix
            }
            return rotationMatrix
        }
        if components.count == 9 {
            // 3x3 rotation matrix
            let matrix = simd_float4x4(
                SIMD4<Float>(components[0], components[1], components[2], 0),
                SIMD4<Float>(components[3], components[4], components[5], 0),
                SIMD4<Float>(components[6], components[7], components[8], 0),
                SIMD4<Float>(0, 0, 0, 1)
            )

            // Apply position if specified
            if let position = config.getCameraPosition() {
                var finalMatrix = matrix
                finalMatrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
                return finalMatrix
            }
            return matrix
        }
        throw ValidationError("Camera rotation must be either 4 values (quaternion x,y,z,w) or 9 values (3x3 matrix)")
    }

    func createProjection(from config: RenderConfig) throws -> any ProjectionProtocol {
        let angleOfView = config.projectionFov.map { AngleF.degrees(Float($0)) } ?? AngleF.degrees(60)
        return PerspectiveProjection(
            verticalAngleOfView: angleOfView,
            depthMode: .standard(zClip: config.near...config.far)
        )
    }
}

// MARK: - Matrix Extensions

extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self.init(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        )
    }
}

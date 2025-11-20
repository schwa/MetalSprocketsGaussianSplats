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

    @MainActor
    mutating func run() throws {
        // Load config from file if specified, otherwise use command-line args
        var renderConfig: RenderConfig
        if let configPath = config {
            renderConfig = try RenderConfig.load(from: configPath)

            // CLI flags override config values
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
        } else {
            // Build config from command-line arguments
            guard let splatPath = splat else {
                throw ValidationError("Must specify a splat file with --splat or use --config")
            }

            let bgComponents = try parseRGBA(background)
            renderConfig = RenderConfig(
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

        // Use renderConfig for everything below
        let bgColor = renderConfig.getBackground()
        let splatPath = renderConfig.splat

        // Load the splat file
        let splatURL = URL(fileURLWithPath: splatPath)
        guard FileManager.default.fileExists(atPath: splatPath) else {
            throw ValidationError("Splat file not found: \(splatPath)")
        }

        // Determine file type and load splats
        let fileExtension = splatURL.pathExtension.lowercased()

        // Load splats based on file type
        #if os(iOS) || (os(macOS) && !arch(x86_64))
        let antimatter15Splats: [Antimatter15Splat]
        var spzSplats: [SPZSplat]?  // Keep SPZ splats for SH extraction

        switch fileExtension {
        case "spz":
            let reader = try SPZReader(url: splatURL)
            var tempSPZSplats: [SPZSplat] = []
            var tempSplats: [Antimatter15Splat] = []
            try reader.read { spzSplat in
                tempSPZSplats.append(spzSplat)
                tempSplats.append(Antimatter15Splat(spzSplat))
            }
            spzSplats = tempSPZSplats
            antimatter15Splats = tempSplats

        case "ply":
            let data = try Data(contentsOf: splatURL)
            let reader = try PLYReader(data: data)
            var tempSplats: [Antimatter15Splat] = []
            try reader.read { record in
                if let splat = Antimatter15Splat(plyRecord: record) {
                    tempSplats.append(splat)
                }
            }
            antimatter15Splats = tempSplats

        case "splat":
            // Antimatter15 .splat format - raw binary, 32 bytes per splat
            let data = try Data(contentsOf: splatURL)
            antimatter15Splats = data.withUnsafeBytes { buffer in
                buffer.withMemoryRebound(to: Antimatter15Splat.self, Array.init)
            }

        default:
            throw ValidationError("Unsupported file format: .\(fileExtension)")
        }

        // Setup Metal device
        let device = _MTLCreateSystemDefaultDevice()

        // Create splat cloud
        let modelMatrix = try parseModelMatrix(from: renderConfig)
        let cameraMatrix = try parseCameraMatrix(from: renderConfig)

        // Determine which renderer to use
        let useSparkRenderer = (renderConfig.renderer ?? "antimatter15").lowercased() == "spark"
        let useSrgbToLinear = renderConfig.srgbToLinear ?? false

        // Convert to appropriate GPU format
        let antimatter15SplatCloud: SplatCloud<Antimatter15GPUSplat>?
        let sparkSplatCloud: SplatCloud<SparkGPUSplat>?
        var shCoefficientsBuffer: TypedMTLBuffer<Float>?
        var effectiveSHDegree: UInt8 = 0

        if useSparkRenderer {
            // For Spark, prefer to convert directly from SPZ if available (preserves SH)
            let gpuSplats: [SparkGPUSplat]
            if let spz = spzSplats {
                gpuSplats = spz.map { SparkGPUSplat($0) }
                // Extract spherical harmonics
                if let (shCoeffs, degree) = spz.extractSphericalHarmonics() {
                    // Apply override if specified
                    let finalDegree = shDegree.map { UInt8(min(max($0, 0), Int(degree))) } ?? degree
                    if finalDegree > 0 {
                        effectiveSHDegree = finalDegree
                        shCoefficientsBuffer = try device.makeTypedBuffer(values: shCoeffs, options: [])
                    }
                }
            } else {
                gpuSplats = antimatter15Splats.map { SparkGPUSplat($0) }
            }
            let splatBuffer = try device.makeTypedBuffer(values: gpuSplats, options: [])
            sparkSplatCloud = try SplatCloud<SparkGPUSplat>(
                device: device,
                splats: splatBuffer,
                cameraMatrix: cameraMatrix,
                modelMatrix: modelMatrix
            )
            antimatter15SplatCloud = nil
        } else {
            let gpuSplats = antimatter15Splats.map { Antimatter15GPUSplat($0) }
            let splatBuffer = try device.makeTypedBuffer(values: gpuSplats, options: [])
            antimatter15SplatCloud = try SplatCloud<Antimatter15GPUSplat>(
                device: device,
                splats: splatBuffer,
                cameraMatrix: cameraMatrix,
                modelMatrix: modelMatrix
            )
            sparkSplatCloud = nil
        }

        // Create projection
        let projection = try createProjection(from: renderConfig)

        // Setup offscreen renderer
        let size = CGSize(width: renderConfig.width, height: renderConfig.height)
        let renderer = try OffscreenRenderer(size: size)

        // Update clear color
        renderer.renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bgColor.x),
            green: Double(bgColor.y),
            blue: Double(bgColor.z),
            alpha: Double(bgColor.w)
        )

        // Create render content
        let splatCount = useSparkRenderer ? sparkSplatCloud!.count : antimatter15SplatCloud!.count

        // Render with Metal capture
        let captureManager = MTLCaptureManager.shared()
        let rendering: OffscreenRenderer.Rendering
        if useSparkRenderer {
            let renderContent = try RenderPass {
                let aspectRatio = Float(size.width) / Float(size.height)
                let projectionMatrix = projection.projectionMatrix(aspectRatio: aspectRatio)
                try SparkSplatRenderPipeline(
                    splatCloud: sparkSplatCloud!,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: SIMD2<Float>(Float(size.width), Float(size.height)),
                    convertSRGBToLinear: useSrgbToLinear,
                    shCoefficients: shCoefficientsBuffer,
                    shDegree: effectiveSHDegree
                )
            }
            rendering = try captureManager.with(enabled: capture) {
                try renderer.render(renderContent)
            }
        } else {
            let renderContent = try RenderPass {
                let aspectRatio = Float(size.width) / Float(size.height)
                let projectionMatrix = projection.projectionMatrix(aspectRatio: aspectRatio)
                try Antimatter15SplatRenderPipeline(
                    splatCloud: antimatter15SplatCloud!,
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

        // Save to PNG
        var cgImage = try rendering.cgImage

        // Add label overlay if requested
        if label {
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
            if let labeledImage = renderer.cgImage {
                cgImage = labeledImage
            }
        }

        // Make output path absolute if it's relative
        var outputPath = renderConfig.output
        if !outputPath.hasPrefix("/") {
            outputPath = FileManager.default.currentDirectoryPath + "/" + outputPath
        }

        // Ensure parent directory exists
        let outputURL = URL(fileURLWithPath: outputPath)
        if let parentDir = outputURL.deletingLastPathComponent().path as String? {
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw ValidationError("Failed to create image destination")
        }

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw ValidationError("Failed to write image to \(renderConfig.output)")
        }

        // Reveal the image in Finder if requested
        if reveal {
            NSWorkspace.shared.selectFile(outputPath, inFileViewerRootedAtPath: "")
        }

        #else
        throw ValidationError("This tool requires Apple Silicon (ARM64) on macOS")
        #endif
    }

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

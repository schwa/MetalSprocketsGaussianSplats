import AppKit
@preconcurrency import ArgumentParser
import Foundation
import GeometryLite3D
import ImageIO
import Metal
import MetalFX
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSupport
import simd
import Splats
import SwiftUI

// The command line follows the splat-render spec
// (~/Projects/Scratch/splat-render/docs/help.txt and spec.md).

@main
struct GaussianSplatRenderer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metalsprockets-gaussian-splat",
        abstract: "Render a Gaussian splat scene to a PNG, and optionally time it.",
        subcommands: [BenchCommand.self],
        helpNames: [.long, .short]
    )

    @Argument(help: ArgumentHelp("Scene to render (.sog, .ply, .splat, .spz).", valueName: "scene"))
    var scene: String?

    @OptionGroup(title: "Input") var input: InputOptions
    @OptionGroup(title: "Output") var output: OutputOptions
    @OptionGroup(title: "Camera") var camera: CameraOptions
    @OptionGroup(title: "Projection") var projection: ProjectionOptions
    @OptionGroup(title: "Quality") var quality: QualityOptions
    @OptionGroup(title: "Timing") var timing: TimingOptions
    @OptionGroup(title: "Extras") var extra: ExtraOptions

    // Exit codes: 64 for a usage error, 65 for an unreadable scene, 1 for a failed render.
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // The positional scene would otherwise swallow the subcommand name.
        if arguments.first == BenchCommand.configuration.commandName {
            await BenchCommand.main(Array(arguments.dropFirst()))
            return
        }
        let command: any ParsableCommand
        do {
            command = try parseAsRoot(normalizeArguments(arguments))
        } catch {
            if exitCode(for: error) == .success {
                print(fullMessage(for: error))
                Foundation.exit(0)
            }
            fail(message(for: error), code: 64)
        }
        guard let root = command as? Self else {
            do {
                var command = command
                if var asyncCommand = command as? any AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            } catch {
                exit(withError: error)
            }
            return
        }
        do {
            #if arch(x86_64)
            throw RenderError("This tool requires Apple Silicon (ARM64) on macOS")
            #else
            let settings = try Settings(command: root)
            try await MainActor.run {
                try render(settings)
            }
            #endif
        } catch let error as UsageError {
            fail(error.message, code: 64)
        } catch let error as SceneError {
            fail(error.message, code: 65)
        } catch let error as RenderError {
            fail(error.message, code: 1)
        } catch {
            fail("\(error)", code: 1)
        }
    }

    /// ArgumentParser has no option with an optional value, so a bare
    /// `--statistics` becomes `--statistics text`.
    static func normalizeArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        for (index, argument) in arguments.enumerated() {
            result.append(argument)
            if argument == "--statistics" || argument == "--stats" {
                let following = index + 1 < arguments.count ? arguments[index + 1] : nil
                if following.flatMap(StatisticsFormat.init(rawValue:)) == nil {
                    result.append(StatisticsFormat.text.rawValue)
                }
            }
        }
        return result
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        Foundation.exit(code)
    }
}

#if !arch(x86_64)
// MARK: - Rendering

@MainActor
private func render(_ settings: Settings) throws {
    // Check the camera before the scene loads, as the spec asks.
    let cameraMatrix = try settings.cameraToWorld()
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw RenderError("no Metal device")
    }
    var upscaleFactor = settings.upscaleFactor
    if upscaleFactor != nil, !MTLFXSpatialScalerDescriptor.supportsMetal4FX(device) {
        FileHandle.standardError.write(Data("warning: this GPU has no MetalFX spatial upscaler; rendering at full size\n".utf8))
        upscaleFactor = nil
    }
    let cloud = try loadScene(path: settings.scene, maximumDegree: settings.sphericalHarmonicsDegree, device: device)

    let libraryRenderer: OffscreenSplatRenderer.Renderer
    switch settings.renderer {
    case .spark:
        libraryRenderer = .spark

    case .point:
        libraryRenderer = .point

    case .tile:
        libraryRenderer = .tile

    case .stochastic:
        libraryRenderer = .stochastic
    }

    let linear = settings.colorSpace == .linear
    var tuning = SplatRenderTuning.default
    tuning.blurAmount = settings.dilation ? 0.3 : 0
    let renderer = try OffscreenSplatRenderer(
        renderer: libraryRenderer,
        splatCloud: cloud,
        projection: PerspectiveProjection(
            verticalAngleOfView: .degrees(Float(settings.projectionFov)),
            depthMode: .standard(zClip: Float(settings.projectionNear)...Float(settings.projectionFar))
        ),
        cameraMatrix: cameraMatrix,
        modelMatrix: settings.modelMatrix(),
        configuration: .init(
            width: settings.width,
            height: settings.height,
            backgroundColor: clearColor(settings: settings),
            convertSRGBToLinear: linear,
            nearPlane: Float(settings.projectionNear),
            farPlane: Float(settings.projectionFar),
            pointSupersampling: settings.supersampling,
            pointPointsPerThread: settings.pointsPerThread,
            collectGPUCounters: settings.statistics != nil,
            sortPrecision: settings.sortPrecision,
            metalFXScale: Float(upscaleFactor ?? 1),
            sparkTuning: tuning,
            // srgb writes splat colors as they are, so the target does no encoding.
            // linear blends in linear space and lets the sRGB target encode.
            colorPixelFormat: linear ? .bgra8Unorm_srgb : .bgra8Unorm
        )
    )

    var samples: [FrameSample] = []
    try MTLCaptureManager.shared().with(enabled: settings.capture) {
        for _ in 0..<settings.warmupFrames {
            try renderer.renderFrame()
        }
        for _ in 0..<settings.measuredFrames {
            let start = ContinuousClock.now
            let report = try renderer.renderFrame()
            samples.append(FrameSample(
                wallTime: elapsedSeconds(since: start),
                sortGPU: report.sortGPU,
                render: report.render,
                visibleSplats: report.visibleSplats,
                commandBufferGPUTime: report.commandBufferGPUTime
            ))
        }
    }

    if let output = settings.output {
        var image = try renderer.makeImage()
        if settings.label {
            image = addLabel(to: image, settings: settings, splatCount: cloud.count, shDegree: cloud.shDegree)
        }
        try savePNG(image, to: output, reveal: settings.reveal)
    }

    if let format = settings.statistics {
        let metalFXScale = settings.renderer == .spark ? upscaleFactor.map(Float.init) : nil
        let report = makeReport(samples: samples, splats: cloud.count, shDegree: Int(cloud.shDegree), width: settings.width, height: settings.height, warmup: settings.warmupFrames, renderer: settings.renderer, metalFXScale: metalFXScale)
        try emitReport(report, samples: samples, scene: settings.scene, format: format)
    }
}

/// The blend is premultiplied, so the clear color is too. In linear mode the
/// background, given in sRGB, is converted to linear first.
private func clearColor(settings: Settings) -> SIMD4<Float> {
    let background = settings.backgroundColor
    let alpha = background.w
    func channel(_ value: Float) -> Float {
        (settings.colorSpace == .linear ? srgbToLinear(value) : value) * alpha
    }
    return SIMD4(channel(background.x), channel(background.y), channel(background.z), alpha)
}

private func srgbToLinear(_ value: Float) -> Float {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}

// MARK: - Label

@MainActor
private func addLabel(to image: CGImage, settings: Settings, splatCount: Int, shDegree: UInt8) -> CGImage {
    let fov = settings.projectionFov.formatted(.number.precision(.fractionLength(0...2)))
    var lines = [
        "metalsprockets-gaussian-splat (\(settings.renderer.rawValue))",
        "\(settings.width)x\(settings.height)  FOV \(fov)°  \(settings.colorSpace.rawValue)",
        "\(splatCount) splats, SH \(shDegree > 0 ? "degree \(shDegree)" : "off")",
        URL(fileURLWithPath: settings.scene).lastPathComponent
    ]
    if let factor = settings.upscaleFactor {
        lines.insert("upscale \(factor.formatted())x", at: 2)
    }
    let labelView = ZStack(alignment: .topLeading) {
        Image(decorative: image, scale: 1.0)
        Text(lines.joined(separator: "\n"))
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
            .padding(8)
            .background(Color.black.opacity(0.7))
            .cornerRadius(4)
            .padding(10)
    }
    let renderer = ImageRenderer(content: labelView)
    renderer.scale = 1.0
    return renderer.cgImage ?? image
}

// MARK: - Output

private func savePNG(_ image: CGImage, to path: String, reveal: Bool) throws {
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
        throw RenderError("cannot write \(path): \(error.localizedDescription)")
    }
    // The texture bytes are already in the output encoding, so tag them sRGB
    // rather than letting ImageIO convert from device RGB.
    let tagged = CGColorSpace(name: CGColorSpace.sRGB).flatMap { image.copy(colorSpace: $0) } ?? image
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw RenderError("cannot write \(path)")
    }
    CGImageDestinationAddImage(destination, tagged, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw RenderError("cannot write \(path)")
    }
    if reveal {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
}
#endif

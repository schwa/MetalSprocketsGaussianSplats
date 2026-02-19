import CoreGraphics
import GeometryLite3D
import ImageIO
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import SwiftUI
import UniformTypeIdentifiers

struct TransferableImage: Transferable {
    let cgImage: CGImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { image in
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw NSError(domain: "TransferableImage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
            }
            CGImageDestinationAddImage(destination, image.cgImage, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw NSError(domain: "TransferableImage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize image"])
            }
            return data as Data
        }
    }
}

struct ScreenshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UnifiedSplatViewModel.self) private var viewModel

    @State private var width: Int
    @State private var height: Int
    @State private var isRendering = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var exportImage: TransferableImage?

    init(defaultWidth: Int, defaultHeight: Int) {
        _width = State(initialValue: defaultWidth)
        _height = State(initialValue: defaultHeight)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Screenshot")
                .font(.headline)

            Form {
                LabeledContent("Width") {
                    TextField("Width", value: $width, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("px")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Height") {
                    TextField("Height", value: $height, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("px")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save…") {
                    Task {
                        renderScreenshot()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRendering || viewModel.descriptor == nil)
            }

            if isRendering {
                ProgressView("Rendering…")
            }
        }
        .padding()
        .frame(width: 300)
        .fileExporter(
            isPresented: $isExporting,
            item: exportImage,
            contentTypes: [.png],
            defaultFilename: "screenshot.png"
        ) { result in
            exportImage = nil
            switch result {
            case .success:
                dismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func renderScreenshot() {
        guard let splatCloud = viewModel.splatCloud else {
            errorMessage = "No splat cloud loaded"
            return
        }

        isRendering = true
        errorMessage = nil

        do {
            // Capture values
            let cameraMatrix = viewModel.cameraMatrix
            let sceneTransform = viewModel.sceneTransform
            let bgColor = viewModel.backgroundColor.resolve(in: .init())

            // Create projection
            let projection = PerspectiveProjection(
                verticalAngleOfView: .degrees(Float(viewModel.verticalAngleOfView)),
                depthMode: .standard(zClip: 0.01 ... 1_000)
            )
            let projectionMatrix = projection.projectionMatrix(for: CGSize(width: width, height: height))

            // Render offscreen using Spark renderer
            let size = CGSize(width: width, height: height)
            var renderer = try OffscreenRenderer(size: size)

            // Set background color from viewModel
            renderer.renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(bgColor.red),
                green: Double(bgColor.green),
                blue: Double(bgColor.blue),
                alpha: 1.0
            )

            let renderPass = try RenderPass {
                try SparkSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: sceneTransform,
                    cameraMatrix: cameraMatrix,
                    drawableSize: SIMD2<Float>(size)
                )
            }

            let rendering = try renderer.render(renderPass)
            let cgImage = try rendering.cgImage

            exportImage = TransferableImage(cgImage: cgImage)
            isExporting = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isRendering = false
    }
}

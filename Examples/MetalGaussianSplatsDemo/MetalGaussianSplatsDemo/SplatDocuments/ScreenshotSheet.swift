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
    @Environment(SplatDocumentViewModel.self) private var viewModel

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
                        await renderScreenshot()
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

    private func renderScreenshot() async {
        guard let descriptor = viewModel.descriptor else {
            errorMessage = "No splat cloud loaded"
            return
        }

        isRendering = true
        errorMessage = nil

        do {
            // Capture values
            let rendererType = viewModel.rendererType
            let cameraMatrix = viewModel.cameraMatrix
            let modelMatrix = viewModel.modelMatrix

            // Load splat cloud
            let splatCloud: AnyGPUSplatCloud
            switch rendererType {
            case .spark, .stochastic, .tileBased:
                let cloud: GPUSplatCloud<SparkSplat> = try descriptor.loadGPUSplatCloud(
                    cameraMatrix: cameraMatrix,
                    modelMatrix: modelMatrix
                )
                splatCloud = AnyGPUSplatCloud(cloud)
            case .antimatter15:
                let cloud: GPUSplatCloud<Antimatter15GPUSplat> = try descriptor.loadGPUSplatCloud(
                    cameraMatrix: cameraMatrix,
                    modelMatrix: modelMatrix
                )
                splatCloud = AnyGPUSplatCloud(cloud)
            }

            // Create projection
            let projection = PerspectiveProjection(
                verticalAngleOfView: .degrees(Float(viewModel.verticalAngleOfView)),
                depthMode: .standard(zClip: 0.01 ... 1_000)
            )

            // Render offscreen
            let size = CGSize(width: width, height: height)
            let renderer = try OffscreenRenderer(size: size)

            let renderPass = SplatRenderPass(
                rendererType: rendererType,
                splatCloud: splatCloud,
                cameraMatrix: cameraMatrix,
                modelMatrix: modelMatrix,
                projection: projection,
                drawableSize: size,
                frame: 0
            )

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

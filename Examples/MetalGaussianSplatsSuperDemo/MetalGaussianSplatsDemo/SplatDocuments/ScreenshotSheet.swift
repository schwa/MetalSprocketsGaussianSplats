#if os(iOS) || os(macOS)
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
    @Environment(SplatViewModel.self) private var viewModel

    let sceneTransform: simd_float4x4
    /// Cloud descriptors and their model transforms for loading fresh clouds
    let cloudInfos: [(descriptor: SplatCloudDescriptor, modelTransform: simd_float4x4)]

    @State private var width: Int
    @State private var height: Int
    @State private var isRendering = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var exportImage: TransferableImage?
    @State private var previewImage: CGImage?

    init(cloudInfos: [(descriptor: SplatCloudDescriptor, modelTransform: simd_float4x4)], sceneTransform: simd_float4x4, defaultWidth: Int, defaultHeight: Int) {
        self.cloudInfos = cloudInfos
        self.sceneTransform = sceneTransform
        _width = State(initialValue: defaultWidth)
        _height = State(initialValue: defaultHeight)
    }

    private let maxPreviewSize: CGFloat = 300

    var body: some View {
        VStack(spacing: 16) {
            Text("Export Screenshot")
                .font(.headline)

            // Preview
            Group {
                if let previewImage {
                    Image(decorative: previewImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: maxPreviewSize, maxHeight: maxPreviewSize)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if isRendering {
                    ProgressView()
                        .frame(width: maxPreviewSize, height: maxPreviewSize * CGFloat(height) / CGFloat(max(width, 1)))
                        .background(Color.black.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Rectangle()
                        .fill(Color.black.opacity(0.1))
                        .frame(width: maxPreviewSize, height: maxPreviewSize * CGFloat(height) / CGFloat(max(width, 1)))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            Text("No Preview")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(maxHeight: maxPreviewSize)

            // Size controls
            HStack(spacing: 16) {
                LabeledContent("Width") {
                    TextField("Width", value: $width, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                LabeledContent("Height") {
                    TextField("Height", value: $height, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

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
                    renderForExport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRendering || cloudInfos.isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
        .onAppear {
            renderPreview()
        }
        .onChange(of: width) {
            renderPreview()
        }
        .onChange(of: height) {
            renderPreview()
        }
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

    private func renderPreview() {
        // Render at a smaller size for preview
        let scale = min(1.0, maxPreviewSize / CGFloat(max(width, height)))
        let previewWidth = Int(CGFloat(width) * scale)
        let previewHeight = Int(CGFloat(height) * scale)

        guard previewWidth > 0, previewHeight > 0, !cloudInfos.isEmpty else {
            previewImage = nil
            return
        }

        isRendering = true
        errorMessage = nil

        // Render synchronously for preview (it's small)
        do {
            let cgImage = try renderToImage(width: previewWidth, height: previewHeight)
            previewImage = cgImage
        } catch {
            errorMessage = "Preview failed: \(error.localizedDescription)"
        }

        isRendering = false
    }

    private func renderForExport() {
        guard !cloudInfos.isEmpty else {
            errorMessage = "No splat clouds loaded"
            return
        }

        isRendering = true
        errorMessage = nil

        do {
            let cgImage = try renderToImage(width: width, height: height)
            exportImage = TransferableImage(cgImage: cgImage)
            isExporting = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isRendering = false
    }

    private func renderToImage(width: Int, height: Int) throws -> CGImage {
        let cameraMatrix = viewModel.cameraMatrix
        let bgColor = viewModel.backgroundColor.resolve(in: .init())

        // Load first cloud only for now (to match CLI behavior)
        guard let firstInfo = cloudInfos.first else {
            throw NSError(domain: "ScreenshotSheet", code: 1, userInfo: [NSLocalizedDescriptionKey: "No clouds to render"])
        }

        let cloud: GPUSplatCloud<SparkSplat> = try firstInfo.descriptor.loadGPUSplatCloud(
            modelTransform: firstInfo.modelTransform
        )

        // Create projection
        let projection = PerspectiveProjection(
            verticalAngleOfView: .degrees(Float(viewModel.verticalAngleOfView)),
            depthMode: .standard(zClip: 0.01 ... 1_000)
        )
        let size = CGSize(width: width, height: height)
        let projectionMatrix = projection.projectionMatrix(for: size)

        // Render offscreen - using single cloud constructor like CLI
        let renderer = try OffscreenRenderer(size: size)

        // Create sort manager and sort synchronously for this single-frame render
        let sortManager = try AsyncSortManager(device: renderer.device, splatClouds: [cloud], capacity: cloud.count)
        let sortParameters = SortParameters(camera: cameraMatrix, model: sceneTransform)
        let sortedIndices = try sortManager.sortNowSync(sortParameters)

        // Set background color from viewModel
        renderer.renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bgColor.red),
            green: Double(bgColor.green),
            blue: Double(bgColor.blue),
            alpha: 1.0
        )

        // Use single-cloud constructor (matches CLI exactly)
        let renderPass = try RenderPass {
            try SparkSplatRenderPipeline(
                splatCloud: cloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: sceneTransform,
                cameraMatrix: cameraMatrix,
                drawableSize: SIMD2<Float>(size),
                sortedIndices: sortedIndices
            )
        }

        let rendering = try renderer.render(renderPass)
        return try rendering.cgImage
    }
}
#endif

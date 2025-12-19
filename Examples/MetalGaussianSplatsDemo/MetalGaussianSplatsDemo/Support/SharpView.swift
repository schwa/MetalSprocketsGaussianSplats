#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import MetalSprocketsGaussianSplats
import Sharp
import simd
import SwiftUI
import UniformTypeIdentifiers

struct SharpView: View {
    @State private var isTargeted = false
    @State private var droppedImageURL: URL?
    @State private var sharp: Sharp?
    @State private var isDownloading = false
    @State private var isConverting = false
    @State private var downloadProgress: Double = 0
    @State private var errorMessage: String?
    @State private var outputPLYURL: URL?
    @State private var splatCloud: SplatCloud<SparkSplat>?

    private let projection: any ProjectionProtocol = PerspectiveProjection()
    @State private var cameraMatrix: simd_float4x4 = LookAt(position: [0, 0, -0.25], target: [0, 0, 0], up: [0, 1, 0]).cameraMatrix
    @State private var modelMatrix: simd_float4x4 = .identity
    @State private var isWiggling = false
    @State private var wiggleAngle: Float = 0
    @State private var wiggleTimer: Timer?
    private let baseCameraDistance: Float = 0.25
    @State private var cameraDistance: Float = 0.25
    @State private var cameraX: Float = 0
    @State private var cameraY: Float = 0
    @State private var dragStart: SIMD2<Float> = .zero
    @State private var magnifyStart: Float = 0.25

    private var modelDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SharpModel")
    }

    private var modelURL: URL? {
        Sharp.cachedModel(in: modelDirectory)
    }

    var body: some View {
        VStack {
            // Main content area
            if let splatCloud {
                SparkSplatView(
                    splatCloud: splatCloud,
                    projection: projection,
                    cameraMatrix: cameraMatrix,
                    modelMatrix: modelMatrix
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if !isWiggling {
                                let sensitivity: Float = 0.001
                                let dx = Float(value.translation.width) * sensitivity
                                let dy = Float(-value.translation.height) * sensitivity
                                cameraX = dragStart.x + dx
                                cameraY = dragStart.y + dy
                                updateCameraFromAngle()
                            }
                        }
                        .onEnded { _ in
                            dragStart = SIMD2<Float>(cameraX, cameraY)
                        }
                )
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if !isWiggling {
                                let newDistance = magnifyStart / Float(value.magnification)
                                cameraDistance = max(-0.5, min(2.0, newDistance))
                                updateCameraFromAngle()
                            }
                        }
                        .onEnded { _ in
                            magnifyStart = cameraDistance
                        }
                )
            } else if let url = droppedImageURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    ProgressView()
                }
            } else {
                Text("Drop Image Here")
                    .foregroundStyle(.secondary)
            }

            if splatCloud != nil {
                VStack(spacing: 4) {
                    HStack {
                        Text("X")
                            .frame(width: 20)
                        Slider(value: $cameraX, in: -0.5...0.5)
                            .onChange(of: cameraX) { updateCameraFromAngle() }
                        Text(String(format: "%.3f", cameraX))
                            .monospacedDigit()
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Y")
                            .frame(width: 20)
                        Slider(value: $cameraY, in: -0.5...0.5)
                            .onChange(of: cameraY) { updateCameraFromAngle() }
                        Text(String(format: "%.3f", cameraY))
                            .monospacedDigit()
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Z")
                            .frame(width: 20)
                        Slider(value: $cameraDistance, in: -0.5...1.0)
                            .onChange(of: cameraDistance) { updateCameraFromAngle() }
                        Text(String(format: "%.3f", cameraDistance))
                            .monospacedDigit()
                            .frame(width: 60)
                    }
                }
                .padding(.horizontal)
            }

            Spacer()

            if isConverting {
                ProgressView("Converting...")
            }

            if let outputPLYURL {
                Link(destination: outputPLYURL) {
                    Label(outputPLYURL.lastPathComponent, systemImage: "doc.fill")
                }
            }

            Divider()
                .padding(.vertical)

            if let modelURL {
                Label("Model Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Link(destination: modelURL) {
                    Label(modelURL.lastPathComponent, systemImage: "folder.fill")
                        .font(.caption)
                }
            } else if isDownloading {
                VStack {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                    Text("Downloading... \(Int(downloadProgress * 100))%")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Download Model") {
                    Task {
                        await downloadModel()
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
        .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            
            if provider.hasItemConformingToTypeIdentifier("public.image") {
                provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    guard let data else { return }
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("png")
                    try? data.write(to: tempURL)
                    Task { @MainActor in
                        droppedImageURL = tempURL
                        splatCloud = nil
                        outputPLYURL = nil
                        await convertImage(tempURL)
                    }
                }
                return true
            } else if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          ["png", "jpg", "jpeg", "heic", "heif", "tiff", "gif"].contains(url.pathExtension.lowercased())
                    else { return }
                    Task { @MainActor in
                        droppedImageURL = url
                        splatCloud = nil
                        outputPLYURL = nil
                        await convertImage(url)
                    }
                }
                return true
            }
            return false
        }
        .onAppear {
            loadModelIfCached()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    modelMatrix = simd_float4x4(zRotation: .radians(.pi / 2)) * modelMatrix
                } label: {
                    Image(systemName: "rotate.left")
                }
                Button {
                    modelMatrix = simd_float4x4(zRotation: .radians(-.pi / 2)) * modelMatrix
                } label: {
                    Image(systemName: "rotate.right")
                }
                Button {
                    toggleWiggle()
                } label: {
                    Image(systemName: isWiggling ? "stop.fill" : "arrow.trianglehead.2.clockwise.rotate.90")
                }
            }
        }
        .onDisappear {
            stopWiggle()
        }
    }

    private func loadModelIfCached() {
        if let url = modelURL, sharp == nil {
            sharp = try? Sharp(modelURL: url)
        }
    }

    private func toggleWiggle() {
        if isWiggling {
            stopWiggle()
        } else {
            startWiggle()
        }
    }

    private func startWiggle() {
        isWiggling = true
        wiggleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            wiggleAngle += 0.03
            let x = sin(wiggleAngle) * cameraDistance * 0.1
            let y = cos(wiggleAngle) * cameraDistance * 0.1
            let z = -cameraDistance + sin(wiggleAngle) * cameraDistance * 0.4
            cameraMatrix = LookAt(position: [x, y, z], target: [0, 0, 0], up: [0, 1, 0]).cameraMatrix
        }
    }

    private func stopWiggle() {
        isWiggling = false
        wiggleTimer?.invalidate()
        wiggleTimer = nil
        updateCameraFromAngle()
    }

    private func updateCameraFromAngle() {
        // Pan camera - both position and target move together
        cameraMatrix = LookAt(position: [cameraX, cameraY, -cameraDistance], target: [cameraX, cameraY, 0], up: [0, 1, 0]).cameraMatrix
    }

    @MainActor
    private func downloadModel() async {
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            sharp = try await Sharp.download(to: modelDirectory) { progress in
                Task { @MainActor in
                    downloadProgress = progress
                }
            }
            if let imageURL = droppedImageURL {
                await convertImage(imageURL)
            }
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }

        isDownloading = false
    }

    private func convertImage(_ imageURL: URL) async {
        guard let sharp else {
            return
        }

        await MainActor.run {
            isConverting = true
            errorMessage = nil
        }

        do {
            // Check image dimensions to determine up vector
            let isLandscape = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                    return true // default to landscape
                }
                // Check EXIF orientation - values 5,6,7,8 swap width/height
                let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                let swapped = orientation >= 5 && orientation <= 8
                let displayWidth = swapped ? height : width
                let displayHeight = swapped ? width : height
                return displayWidth >= displayHeight
            }.value

            // Rotate model based on orientation - landscape 180°, portrait 90° CCW
            let newModelMatrix: simd_float4x4 = isLandscape ? simd_float4x4(zRotation: .radians(.pi)) : simd_float4x4(zRotation: .radians(.pi / 2))

            let outputDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SharpOutput")
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let outputName = imageURL.deletingPathExtension().lastPathComponent + ".ply"
            let outputURL = outputDir.appendingPathComponent(outputName)

            let cameraMatrix = self.cameraMatrix
            let (plyURL, cloud) = try await Task.detached {
                try sharp.convert(from: imageURL, to: outputURL)
                let cloud = try SplatCloud<SparkSplat>(url: outputURL, cameraMatrix: cameraMatrix)
                return (outputURL, cloud)
            }.value

            await MainActor.run {
                modelMatrix = newModelMatrix
                outputPLYURL = plyURL
                splatCloud = cloud
            }
        } catch {
            await MainActor.run {
                errorMessage = "Conversion failed: \(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isConverting = false
        }
    }
}

#endif

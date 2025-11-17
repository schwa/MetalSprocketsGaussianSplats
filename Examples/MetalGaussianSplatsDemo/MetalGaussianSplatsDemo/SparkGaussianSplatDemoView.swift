#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
internal import os
import SwiftUI
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprockets
import Interaction3D
import Metal
import MetalSprocketsUI
import UniformTypeIdentifiers

public struct SparkGaussianSplatDemoView: View {
    @State
    private var splatCloud: SplatCloud<SparkGPUSplat>?

    @State
    private var projection: any ProjectionProtocol = PerspectiveProjection()

    @State
    private var cameraMatrix: simd_float4x4 = .init(translation: [0, 0.5, 1.5])

    @State
    private var modelMatrix: simd_float4x4 = .identity

    @State
    private var rotationX: Float = 0

    @State
    private var rotationY: Float = 0

    @State
    private var rotationZ: Float = 0

    @State
    private var selectedSplatFile: String = "centered_lastchance"

    @State
    private var showingImporter = false

    @State
    private var showingRotationPopover = false

    public init() {
        // This line intentionally left blank.
    }

    public var body: some View {
        ZStack {
            Color.black
            if let splatCloud {
                WorldView(projection: $projection, cameraMatrix: $cameraMatrix) {
                    SparkSplatView(splatCloud: splatCloud, projection: projection, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
                }
            }
        }
        .toolbar {
            toolbar
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.antimatter15Splat, .spz, .ply]) { result in
            Task {
                switch result {
                case .success(let url):
                    // Request access to the security-scoped resource
                    guard url.startAccessingSecurityScopedResource() else {
                        print("Failed to access security-scoped resource")
                        return
                    }
                    defer {
                        url.stopAccessingSecurityScopedResource()
                    }

                    do {
                        splatCloud = try await load(url: url)
                    } catch {
                        print("Failed to load splat file: \(error)")
                    }
                case .failure(let error):
                    print("File import failed: \(error)")
                }
            }
        }
        .onChange(of: rotationX) { updateModelMatrix() }
        .onChange(of: rotationY) { updateModelMatrix() }
        .onChange(of: rotationZ) { updateModelMatrix() }
        .task(id: selectedSplatFile) {
            if let url = Bundle.main.url(forResource: selectedSplatFile, withExtension: "spz") {
                splatCloud = try? await load(url: url)
            }
        }
    }

    func load(url: URL) async throws -> SplatCloud<SparkGPUSplat> {
        let device = _MTLCreateSystemDefaultDevice()

        switch url.pathExtension.lowercased() {
        case "spz":
            let reader = try SPZReader(url: url)
            var splats: [SparkGPUSplat] = []
            splats.reserveCapacity(Int(reader.pointCount))

            try reader.read { spzSplat in
                let sparkSplat = SparkGPUSplat(spzSplat)
                splats.append(sparkSplat)
            }

            return try SplatCloud(device: device, splats: splats, cameraMatrix: .identity, modelMatrix: .identity)

        case "splat":
            // Load .splat file (Antimatter15 format: 32 bytes per splat)
            let data = try Data(contentsOf: url)
            let splatSize = MemoryLayout<Antimatter15Splat>.size  // 32 bytes
            let count = data.count / splatSize

            var splats: [SparkGPUSplat] = []
            splats.reserveCapacity(count)

            data.withUnsafeBytes { buffer in
                let am15Splats = buffer.bindMemory(to: Antimatter15Splat.self)
                for i in 0..<count {
                    let sparkSplat = SparkGPUSplat(am15Splats[i])
                    splats.append(sparkSplat)
                }
            }

            return try SplatCloud(device: device, splats: splats, cameraMatrix: .identity, modelMatrix: .identity)

        case "ply":
            // Load .ply file (3DGS training output format)
            let reader = try PLYReader(url: url)
            var splats: [SparkGPUSplat] = []
            splats.reserveCapacity(reader.recordCount)

            try reader.read { record in
                if let sparkSplat = SparkGPUSplat(plyRecord: record) {
                    splats.append(sparkSplat)
                }
            }

            return try SplatCloud(device: device, splats: splats, cameraMatrix: .identity, modelMatrix: .identity)

        default:
            throw NSError(domain: "SparkDemo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported file format: \(url.pathExtension)"])
        }
    }

    func updateModelMatrix() {
        let rotX = float4x4(xRotation: .radians(rotationX))
        let rotY = float4x4(yRotation: .radians(rotationY))
        let rotZ = float4x4(zRotation: .radians(rotationZ))
        modelMatrix = rotZ * rotY * rotX
    }

    @ViewBuilder
    var toolbar: some View {
        if let splatCloud {
            Text("\(splatCloud.count.formatted()) splats")
                .foregroundStyle(.secondary)
        }

        Button("Load") {
            showingImporter = true
        }

        Picker("Splat File", selection: $selectedSplatFile) {
            Text("Last Chance").tag("centered_lastchance")
            Text("Train").tag("train")
        }

        Button("Adjust Axes") {
            showingRotationPopover = true
        }
        .popover(isPresented: $showingRotationPopover) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Adjust Coordinate Axes")
                    .font(.headline)

                Button("Quick Fix: X=90° Z=180°") {
                    rotationX = Float.pi / 2
                    rotationY = 0
                    rotationZ = Float.pi
                }
                .buttonStyle(.borderedProminent)

                Divider()

                Picker("Rotate X", selection: $rotationX) {
                    Text("0°").tag(Float(0))
                    Text("90°").tag(Float.pi / 2)
                    Text("180°").tag(Float.pi)
                    Text("270°").tag(Float.pi * 3 / 2)
                }

                Picker("Rotate Y", selection: $rotationY) {
                    Text("0°").tag(Float(0))
                    Text("90°").tag(Float.pi / 2)
                    Text("180°").tag(Float.pi)
                    Text("270°").tag(Float.pi * 3 / 2)
                }

                Picker("Rotate Z", selection: $rotationZ) {
                    Text("0°").tag(Float(0))
                    Text("90°").tag(Float.pi / 2)
                    Text("180°").tag(Float.pi)
                    Text("270°").tag(Float.pi * 3 / 2)
                }

                Button("Done") {
                    showingRotationPopover = false
                }
            }
            .padding()
            .frame(minWidth: 250)
        }
    }
}

#endif

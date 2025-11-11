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

public struct GaussianSplatDemoView: View {
    @State
    private var splatCloud: SplatCloud<GPUSplat>?

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
    private var debugMode: GaussianSplatRenderPipeline.DebugMode = .off

    @State
    private var selectedSplatFile: String = "centered_lastchance"

    @State
    private var showTileOverlay = false

    @State
    private var tileSize: UInt32 = 16

    @State
    private var drawableSize: CGSize = .zero

    @State
    var bufferPool = Pool<TypedMTLBuffer<UInt32>>(elements: [])

    @State
    var currentTileBuffer: TypedMTLBuffer<UInt32>?

    @State
    var maxCountBuffer: TypedMTLBuffer<UInt32>?

    @State
    var tileStats: TileStats?

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
                    RenderView { _, drawableSize in
                        try Group {
                            let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                            let drawableSizeFloat = SIMD2<Float>(drawableSize)
                            let gridWidth = UInt32(ceil(drawableSizeFloat.x / Float(tileSize)))
                            let gridHeight = UInt32(ceil(drawableSizeFloat.y / Float(tileSize)))
                            let tileGridSize = SIMD2<UInt32>(gridWidth, gridHeight)

                            try RenderPass {
                                try GaussianSplatRenderPipeline(splatCloud: splatCloud, projectionMatrix: projectionMatrix, modelMatrix: modelMatrix, cameraMatrix: cameraMatrix, drawableSize: drawableSizeFloat, debugMode: debugMode)
                            }
                            if let currentTileBuffer, let maxCountBuffer {
                                try TileCountComputePass(splatCloud: splatCloud, projectionMatrix: projectionMatrix, modelMatrix: modelMatrix, cameraMatrix: cameraMatrix, drawableSize: drawableSizeFloat, tileSize: tileSize, tileBuffer: currentTileBuffer, maxCountBuffer: maxCountBuffer)

                                if showTileOverlay {
                                    try RenderPass {
                                        try TileHeatMapRenderPipeline(tileGridSize: tileGridSize, tileCounts: currentTileBuffer, maxCountBuffer: maxCountBuffer)
                                    }
                                }
                            }
                        }
                        .onCommandBufferCompleted { _ in
                            let oldBuffer = self.currentTileBuffer
                            self.currentTileBuffer = bufferPool.acquire()
                            if let oldBuffer {
                                process(buffer: oldBuffer)
                                bufferPool.release(oldBuffer)
                            }
                        }
                    }
                    .onDrawableSizeChange { drawableSize in
                        self.drawableSize = drawableSize
                    }
                }
            }

            if showTileOverlay, let tileStats {
                TileStatsView(counts: tileStats.counts, gridSize: tileStats.gridSize, tileSize: $tileSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .toolbar {
            toolbar
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.init(filenameExtension: "splat")!]) { result in
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
        .onChange(of: tileSize) {
            try! createTileCountBuffers()
        }
        .onChange(of: drawableSize) {
            guard drawableSize != .zero else { return }
            try! createTileCountBuffers()
        }
        .onChange(of: rotationX) { updateModelMatrix() }
        .onChange(of: rotationY) { updateModelMatrix() }
        .onChange(of: rotationZ) { updateModelMatrix() }
        .task(id: selectedSplatFile) {
            let url = Bundle.main.url(forResource: selectedSplatFile, withExtension: "splat")!
            splatCloud = try! await load(url: url)
        }
    }

    func load(url: URL) async throws -> SplatCloud<GPUSplat> {
        let antimatterSplats = try await [Antimatter15Splat](importing: url, contentType: nil)
        let gpuSplats = antimatterSplats.map(GPUSplat.init)
        let device = MTLCreateSystemDefaultDevice()!
        return try SplatCloud(device: device, splats: gpuSplats, cameraMatrix: cameraMatrix, modelMatrix: .identity)
    }

    func process(splats: [Antimatter15Splat]) {
        let splats = splats.map(GPUSplat.init)
        let device = _MTLCreateSystemDefaultDevice()
        splatCloud = try! SplatCloud(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: .identity)
    }

    private func createTileCountBuffers() throws {
        let device = _MTLCreateSystemDefaultDevice()
        let drawableSizeFloat = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        let gridWidth = UInt32(ceil(drawableSizeFloat.x / Float(tileSize)))
        let gridHeight = UInt32(ceil(drawableSizeFloat.y / Float(tileSize)))
        let capacity = Int(gridWidth * gridHeight)

        guard capacity > 0 else {
            return
        }

        let zeros = Array(repeating: UInt32(0), count: capacity)
        let bufferA = try device.makeTypedBuffer(values: zeros, options: .storageModeShared).labeled("Buffer A")
        let bufferB = try device.makeTypedBuffer(values: zeros, options: .storageModeShared).labeled("Buffer B")
        bufferPool = Pool(elements: [bufferA, bufferB])

        currentTileBuffer = bufferPool.acquire()

        // Create max count buffer (single UInt32)
        maxCountBuffer = try device.makeTypedBuffer(element: UInt32.self, capacity: 1, options: .storageModeShared).labeled("Max Count")
    }

    func process(buffer: TypedMTLBuffer<UInt32>) {
        let drawableSizeFloat = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        let gridWidth = UInt32(ceil(drawableSizeFloat.x / Float(tileSize)))
        let gridHeight = UInt32(ceil(drawableSizeFloat.y / Float(tileSize)))
        let gridSize = SIMD2<UInt32>(gridWidth, gridHeight)

        let counts = buffer.map { $0 }
        tileStats = TileStats(counts: counts, gridSize: gridSize)
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

        Button(showTileOverlay ? "Hide Heat Map" : "Show Heat Map") {
            showTileOverlay.toggle()
        }

        Picker("Debug Mode", selection: $debugMode) {
            Text("Off").tag(GaussianSplatRenderPipeline.DebugMode.off)
            Text("Wireframe").tag(GaussianSplatRenderPipeline.DebugMode.wireframe)
            Text("Filled").tag(GaussianSplatRenderPipeline.DebugMode.filled)
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

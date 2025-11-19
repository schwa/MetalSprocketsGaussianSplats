#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import SwiftUI
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprockets
import Interaction3D
import Metal
import MetalSprocketsUI

struct Antimatter15RendererView: View {
    let url: URL?
    let projection: any ProjectionProtocol
    let cameraMatrix: simd_float4x4
    let modelMatrix: simd_float4x4

    @State private var splatCloud: SplatCloud<Antimatter15GPUSplat>?
    @State private var debugMode: Antimatter15SplatRenderPipeline.DebugMode = .off
    @State private var showTileOverlay = false
    @State private var tileSize: UInt32 = 16
    @State private var drawableSize: CGSize = .zero
    @State private var bufferPool = Pool<TypedMTLBuffer<UInt32>>(elements: [])
    @State private var currentTileBuffer: TypedMTLBuffer<UInt32>?
    @State private var maxCountBuffer: TypedMTLBuffer<UInt32>?
    @State private var tileStats: TileStats?

    var body: some View {
        ZStack {
            if let splatCloud {
                RenderView { _, drawableSize in
                    try Group {
                        let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                        let drawableSizeFloat = SIMD2<Float>(drawableSize)
                        let gridWidth = UInt32(ceil(drawableSizeFloat.x / Float(tileSize)))
                        let gridHeight = UInt32(ceil(drawableSizeFloat.y / Float(tileSize)))
                        let tileGridSize = SIMD2<UInt32>(gridWidth, gridHeight)

                        try RenderPass {
                            try Antimatter15SplatRenderPipeline(splatCloud: splatCloud, projectionMatrix: projectionMatrix, modelMatrix: modelMatrix, cameraMatrix: cameraMatrix, drawableSize: drawableSizeFloat, debugMode: debugMode)
                        }
                        if let currentTileBuffer, let maxCountBuffer {
                            try Antimatter15TileCountComputePass(splatCloud: splatCloud, projectionMatrix: projectionMatrix, modelMatrix: modelMatrix, cameraMatrix: cameraMatrix, drawableSize: drawableSizeFloat, tileSize: tileSize, tileBuffer: currentTileBuffer, maxCountBuffer: maxCountBuffer)

                            if showTileOverlay {
                                try RenderPass {
                                    try Antimatter15TileHeatMapRenderPipeline(tileGridSize: tileGridSize, tileCounts: currentTileBuffer, maxCountBuffer: maxCountBuffer)
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

            if showTileOverlay, let tileStats {
                TileStatsView(counts: tileStats.counts, gridSize: tileStats.gridSize, tileSize: $tileSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .toolbar {
            ToolbarItem {
                Button(showTileOverlay ? "Hide Heat Map" : "Show Heat Map") {
                    showTileOverlay.toggle()
                }
            }

            ToolbarItem {
                Picker("Debug Mode", selection: $debugMode) {
                    Text("Off").tag(Antimatter15SplatRenderPipeline.DebugMode.off)
                    Text("Wireframe").tag(Antimatter15SplatRenderPipeline.DebugMode.wireframe)
                    Text("Filled").tag(Antimatter15SplatRenderPipeline.DebugMode.filled)
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
        .task {
            await loadSplatCloud()
        }
        .onChange(of: url) {
            Task {
                await loadSplatCloud()
            }
        }
    }

    private func loadSplatCloud() async {
        guard let url else { return }
        splatCloud = try! await SplatCloud(url: url, cameraMatrix: cameraMatrix)
    }

    private func createTileCountBuffers() throws {
        let device = _MTLCreateSystemDefaultDevice()
        let drawableSizeFloat = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        let gridWidth = UInt32(ceil(drawableSizeFloat.x / Float(tileSize)))
        let gridHeight = UInt32(ceil(drawableSizeFloat.y / Float(tileSize)))
        let capacity = Int(gridWidth * gridHeight)

        guard capacity > 0 else { return }

        let zeros = Array(repeating: UInt32(0), count: capacity)
        let bufferA = try device.makeTypedBuffer(values: zeros, options: .storageModeShared).labeled("Buffer A")
        let bufferB = try device.makeTypedBuffer(values: zeros, options: .storageModeShared).labeled("Buffer B")
        bufferPool = Pool(elements: [bufferA, bufferB])
        currentTileBuffer = bufferPool.acquire()
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
}

#endif

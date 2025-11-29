#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsSupport
import MetalSprocketsUI
import simd
import SwiftUI

struct HeatMapLegend: View {
    let maxCount: UInt32

    var body: some View {
        let q1 = maxCount / 3
        let q2 = maxCount * 2 / 3

        VStack(alignment: .leading, spacing: 4) {
            Text("Splats/Tile").font(.headline)
            HStack(spacing: 0) {
                // Gradient bar
                LinearGradient(
                    colors: [.blue, .green, .yellow, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 150, height: 16)
                .cornerRadius(2)
            }
            HStack {
                Text("0")
                Spacer()
                Text("\(q1)")
                Spacer()
                Text("\(q2)")
                Spacer()
                Text("\(maxCount)")
            }
            .frame(width: 150)
        }
        .monospacedDigit()
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}

struct FPSOverlay: View {
    var fps: Double

    private var fpsColor: Color {
        switch fps {
        case 55...:
            return .green
        case 45..<55:
            return .yellow
        case 30..<45:
            return .orange
        default:
            return .red
        }
    }

    var body: some View {
        Text(String(format: "%.1f FPS", fps))
            .font(.system(.body, design: .monospaced, weight: .semibold))
            .foregroundStyle(fpsColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct TileStatsOverlay: View {
    let resources: TileSplatResources
    var updateCounter: Int = 0
    @Binding var maxOverlapsEver: UInt64

    var body: some View {
        let _ = updateCounter
        let counts = resources.readTileCounts()
        let gridSize = resources.tileGridSize
        let nonZero = counts.filter { $0 > 0 }
        let maxCount = counts.max() ?? 0
        let total = UInt64(counts.reduce(0) { $0 + UInt64($1) })
        let avg = nonZero.isEmpty ? 0.0 : Double(total) / Double(nonZero.count)
        let sorted = nonZero.sorted()
        let median = sorted.isEmpty ? UInt32(0) : sorted[sorted.count / 2]
        let p95 = sorted.isEmpty ? UInt32(0) : sorted[Int(Double(sorted.count - 1) * 0.95)]
        let p99 = sorted.isEmpty ? UInt32(0) : sorted[Int(Double(sorted.count - 1) * 0.99)]

        let _ = {
            if total > maxOverlapsEver {
                maxOverlapsEver = total
            }
        }()

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Tile Stats").font(.headline)
                    .gridCellColumns(2)
            }
            Divider().gridCellColumns(2)
            GridRow {
                Text("Grid")
                Text("\(gridSize.x) x \(gridSize.y)")
            }
            GridRow {
                Text("Active tiles")
                Text("\(nonZero.count) / \(counts.count)")
            }
            GridRow {
                Text("Total overlaps")
                Text("\(total)")
            }
            GridRow {
                Text("Max overlaps")
                Text("\(maxOverlapsEver)")
            }
            Divider().gridCellColumns(2)
            GridRow {
                Text("Max")
                Text("\(maxCount)")
            }
            GridRow {
                Text("Avg")
                Text(String(format: "%.1f", avg))
            }
            GridRow {
                Text("Median")
                Text("\(median)")
            }
            GridRow {
                Text("P95")
                Text("\(p95)")
            }
            GridRow {
                Text("P99")
                Text("\(p99)")
            }
        }
        .monospacedDigit()
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}

struct TileBasedDemoView: View {
    let url: URL?
    let projection: any ProjectionProtocol
    let cameraMatrix: simd_float4x4
    let modelMatrix: simd_float4x4
    var onFrameCompleted: (@Sendable () -> Void)?

    @State private var splatCloud: SplatCloud<SparkSplat>?
    @State private var debugTileBorders = false
    @State private var showHeatMap = false
    @State private var showStats = false
    @State private var tileSplatResources: TileSplatResources?
    @State private var statsUpdateCounter = 0
    @State private var maxOverlapsEver: UInt64 = 0

    var body: some View {
        ZStack {
            if let splatCloud {
                TileBasedSplatView(
                    splatCloud: splatCloud,
                    projection: projection,
                    cameraMatrix: cameraMatrix,
                    modelMatrix: modelMatrix,
                    debugTileBorders: debugTileBorders,
                    showHeatMap: showHeatMap,
                    onFrameCompleted: { resources in
                        Task { @MainActor in
                            tileSplatResources = resources
                            statsUpdateCounter += 1
                        }
                        onFrameCompleted?()
                    }
                )
            }
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading) {
                Toggle("Tile Borders", isOn: $debugTileBorders)
                Toggle("Heat Map", isOn: $showHeatMap)
                Toggle("Stats", isOn: $showStats)
            }
            .toggleStyle(.switch)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            if showStats, let resources = tileSplatResources {
                TileStatsOverlay(resources: resources, updateCounter: statsUpdateCounter, maxOverlapsEver: $maxOverlapsEver)
                    .padding()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showHeatMap, let resources = tileSplatResources {
                let _ = statsUpdateCounter // Force refresh on counter change
                let maxCount = resources.readTileCounts().max() ?? 0
                HeatMapLegend(maxCount: maxCount)
                    .padding()
            }
        }
        .onChange(of: url, initial: true) {
            Task {
                loadSplatCloud()
            }
        }
    }

    private func loadSplatCloud() {
        guard let url else {
            return
        }

        splatCloud = try! SplatCloud(url: url, cameraMatrix: cameraMatrix)
    }
}

#endif

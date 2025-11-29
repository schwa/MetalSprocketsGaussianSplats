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

struct TileStatsOverlay: View {
    let resources: TileSplatResources

    var body: some View {
        let counts = resources.readTileCounts()
        let gridSize = resources.tileGridSize
        let nonZero = counts.filter { $0 > 0 }
        let maxCount = counts.max() ?? 0
        let total = counts.reduce(0, +)
        let avg = nonZero.isEmpty ? 0.0 : Double(total) / Double(nonZero.count)
        let sorted = nonZero.sorted()
        let median = sorted.isEmpty ? UInt32(0) : sorted[sorted.count / 2]
        let p95 = sorted.isEmpty ? UInt32(0) : sorted[Int(Double(sorted.count - 1) * 0.95)]
        let p99 = sorted.isEmpty ? UInt32(0) : sorted[Int(Double(sorted.count - 1) * 0.99)]

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

    @State private var splatCloud: SplatCloud<SparkSplat>?
    @State private var debugTileBorders = false
    @State private var showHeatMap = false
    @State private var showStats = false
    @State private var tileSplatResources: TileSplatResources?

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
                    onResourcesChanged: { resources in
                        tileSplatResources = resources
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
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    TileStatsOverlay(resources: resources)
                }
                .padding()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showHeatMap, let resources = tileSplatResources {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let maxCount = resources.readTileCounts().max() ?? 0
                    HeatMapLegend(maxCount: maxCount)
                }
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

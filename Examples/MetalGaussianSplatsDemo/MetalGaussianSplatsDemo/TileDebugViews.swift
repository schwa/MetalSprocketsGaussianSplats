#if os(iOS) || (os(macOS) && !arch(x86_64))
import MetalSprocketsGaussianSplats
import SwiftUI

struct TileStatsOverlay: View {
    let resources: TileSplatResources
    var updateCounter: Int = 0
    @Binding var maxOverlapsEver: UInt64

    var body: some View {
        _ = updateCounter
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

        _ = {
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

struct HeatMapLegend: View {
    let maxCount: UInt32

    var body: some View {
        let q1 = maxCount / 3
        let q2 = maxCount * 2 / 3

        VStack(alignment: .leading, spacing: 4) {
            Text("Splats/Tile").font(.headline)
            HStack(spacing: 0) {
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

struct TileDebugToggles: View {
    @Binding var debugTileBorders: Bool
    @Binding var showHeatMap: Bool
    @Binding var showStats: Bool

    var body: some View {
        VStack(alignment: .leading) {
            Toggle("Tile Borders", isOn: $debugTileBorders)
            Toggle("Heat Map", isOn: $showHeatMap)
            Toggle("Stats", isOn: $showStats)
        }
        .toggleStyle(.switch)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

#endif

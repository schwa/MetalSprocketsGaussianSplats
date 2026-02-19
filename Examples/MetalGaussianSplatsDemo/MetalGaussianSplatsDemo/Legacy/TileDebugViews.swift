#if !arch(x86_64)
import MetalSprocketsGaussianSplats
import SwiftUI

struct TileStatsOverlay: View {
    let resources: TileSplatResources
    var updateCounter: Int = 0
    @Binding var maxOverlapsEver: UInt64

    private var stats: TileOverlayStats {
        let counts = resources.readTileCounts()
        let nonZero = counts.filter { $0 > 0 }
        let total = UInt64(counts.reduce(0) { $0 + UInt64($1) })
        let sorted = nonZero.sorted()
        return TileOverlayStats(
            gridSize: resources.tileGridSize,
            counts: counts,
            nonZero: nonZero,
            maxCount: counts.max() ?? 0,
            total: total,
            avg: nonZero.isEmpty ? 0.0 : Double(total) / Double(nonZero.count),
            median: sorted.isEmpty ? UInt32(0) : sorted[sorted.count / 2],
            p95: sorted.isEmpty ? UInt32(0) : sorted[Int(Double(sorted.count - 1) * 0.95)],
            p99: sorted.isEmpty ? UInt32(0) : sorted[Int(Double(sorted.count - 1) * 0.99)]
        )
    }

    var body: some View {
        let currentStats = stats
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Tile Stats").font(.headline)
                    .gridCellColumns(2)
            }
            Divider().gridCellColumns(2)
            GridRow {
                Text("Grid")
                Text("\(currentStats.gridSize.x) x \(currentStats.gridSize.y)")
            }
            GridRow {
                Text("Active tiles")
                Text("\(currentStats.nonZero.count) / \(currentStats.counts.count)")
            }
            GridRow {
                Text("Total overlaps")
                Text("\(currentStats.total)")
            }
            GridRow {
                Text("Max overlaps")
                Text("\(maxOverlapsEver)")
            }
            Divider().gridCellColumns(2)
            GridRow {
                Text("Max")
                Text("\(currentStats.maxCount)")
            }
            GridRow {
                Text("Avg")
                Text(currentStats.avg.formatted(.number.precision(.fractionLength(1))))
            }
            GridRow {
                Text("Median")
                Text("\(currentStats.median)")
            }
            GridRow {
                Text("P95")
                Text("\(currentStats.p95)")
            }
            GridRow {
                Text("P99")
                Text("\(currentStats.p99)")
            }
        }
        .monospacedDigit()
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
        .onChange(of: currentStats.total) { _, newTotal in
            if newTotal > maxOverlapsEver {
                maxOverlapsEver = newTotal
            }
        }
    }
}

private struct TileOverlayStats: Equatable {
    let gridSize: SIMD2<UInt32>
    let counts: [UInt32]
    let nonZero: [UInt32]
    let maxCount: UInt32
    let total: UInt64
    let avg: Double
    let median: UInt32
    let p95: UInt32
    let p99: UInt32
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

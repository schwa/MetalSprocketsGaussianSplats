#if !arch(x86_64)
import Charts
import SwiftUI

struct TileStats {
    let counts: [UInt32]
    let gridSize: SIMD2<UInt32>
}

struct TileStatsView: View {
    let counts: [UInt32]
    let gridSize: SIMD2<UInt32>
    @Binding var tileSize: UInt32

    var body: some View {
        stats
            .frame(maxWidth: 480)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()
    }

    @ViewBuilder
    var stats: some View {
        let maxCount = counts.max() ?? 1
        let total = counts.reduce(0, +)
        let nonZero = counts.filter { $0 > 0 }
        let nonZeroCount = nonZero.count
        let avg = nonZeroCount > 0 ? Double(total) / Double(nonZeroCount) : 0
        let sorted = nonZero.sorted()
        let median = sorted.isEmpty ? 0 : (sorted.count.isMultiple(of: 2) ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2])

        Form {
            Section {
                Text("Tile Statistics")
            }

            Section("Controls") {
                Picker("Tile Size", selection: $tileSize) {
                    Text("8x8").tag(UInt32(8))
                    Text("16x16").tag(UInt32(16))
                    Text("32x32").tag(UInt32(32))
                }
                .pickerStyle(.segmented)
            }

            Section("Coverage") {
                LabeledContent("Active tiles") {
                    Text("\(nonZeroCount)")
                }
                LabeledContent("Total tiles") {
                    Text("\(counts.count)")
                }
                LabeledContent("Active percentage") {
                    Text((Double(nonZeroCount) * 100.0 / Double(counts.count)).formatted(.number.precision(.fractionLength(1))) + "%")
                }
                LabeledContent("Empty tiles") {
                    Text("\(counts.count - nonZeroCount)")
                }
            }

            Section("Distribution") {
                LabeledContent("Total overlaps") {
                    Text("\(total)")
                }
                LabeledContent("Min") {
                    Text("\(sorted.first ?? 0)")
                }
                LabeledContent("Max") {
                    Text("\(maxCount)")
                }
                LabeledContent("Avg per active") {
                    Text(avg.formatted(.number.precision(.fractionLength(1))))
                }
                LabeledContent("Median") {
                    Text("\(median)")
                }
            }

            if !sorted.isEmpty {
                let p25 = percentile(sorted, 0.25)
                let p75 = percentile(sorted, 0.75)
                let p90 = percentile(sorted, 0.90)
                let p95 = percentile(sorted, 0.95)
                let p99 = percentile(sorted, 0.99)

                Section("Percentiles") {
                    LabeledContent("25th") {
                        Text("\(p25)")
                    }
                    LabeledContent("75th") {
                        Text("\(p75)")
                    }
                    LabeledContent("90th") {
                        Text("\(p90)")
                    }
                    LabeledContent("95th") {
                        Text("\(p95)")
                    }
                    LabeledContent("99th") {
                        Text("\(p99)")
                    }
                }

                // Distribution chart
                let histogram = createHistogram(sorted)
                if !histogram.isEmpty {
                    Section("Distribution Chart") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Y-axis: Number of tiles")
                            Text("X-axis: Splats per tile")

                            Chart(histogram) { bin in
                                LineMark(
                                    x: .value("Range", bin.label),
                                    y: .value("Count", bin.count)
                                )
                                .foregroundStyle(.blue)
                                .interpolationMethod(.catmullRom)

                                PointMark(
                                    x: .value("Range", bin.label),
                                    y: .value("Count", bin.count)
                                )
                                .foregroundStyle(.blue)
                            }
                            .frame(height: 120)
                            .chartXAxis {
                                AxisMarks(position: .bottom)
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading)
                            }
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    // Helper functions for statistics
    private func percentile(_ sorted: [UInt32], _ p: Double) -> UInt32 {
        guard !sorted.isEmpty else {
            return 0
        }
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }

    private func createHistogram(_ sorted: [UInt32]) -> [HistogramBin] {
        guard !sorted.isEmpty else {
            return []
        }
        guard let min = sorted.first, let max = sorted.last else {
            return []
        }

        // Use percentiles to create adaptive bins
        let p25 = percentile(sorted, 0.25)
        let p50 = percentile(sorted, 0.50)
        let p75 = percentile(sorted, 0.75)
        let p90 = percentile(sorted, 0.90)
        let p95 = percentile(sorted, 0.95)
        let p99 = percentile(sorted, 0.99)

        var bins: [HistogramBin] = []

        // Create bins based on percentiles to ensure good distribution
        var boundaries: [UInt32] = [min]

        // Add percentile boundaries (avoiding duplicates)
        for value in [p25, p50, p75, p90, p95, p99, max] where value > boundaries.last! {
            boundaries.append(value)
        }

        // Create bins from boundaries
        for i in 0..<(boundaries.count - 1) {
            let start = boundaries[i]
            let end = boundaries[i + 1]

            let label: String
            if i == boundaries.count - 2 {
                // Last bin
                label = "\(start)+"
            } else {
                label = "\(start)-\(end)"
            }

            bins.append(HistogramBin(label: label, min: start, max: end))
        }

        // Count values in each bin
        for i in bins.indices {
            bins[i].count = sorted.filter { $0 >= bins[i].min && $0 <= bins[i].max }.count
        }

        return bins
    }
}

struct HistogramBin: Identifiable {
    let id = UUID()
    let label: String
    var count: Int = 0
    let min: UInt32
    let max: UInt32
}
#endif

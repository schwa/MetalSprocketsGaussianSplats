#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsSupport
import MetalSprocketsUI
import simd
import SwiftUI

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
                    showHeatMap: showHeatMap
                ) { resources in
                    Task { @MainActor in
                        tileSplatResources = resources
                        statsUpdateCounter += 1
                    }
                    onFrameCompleted?()
                }
            }
        }
        .overlay(alignment: .topLeading) {
            TileDebugToggles(
                debugTileBorders: $debugTileBorders,
                showHeatMap: $showHeatMap,
                showStats: $showStats
            )
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
                let _ = statsUpdateCounter
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

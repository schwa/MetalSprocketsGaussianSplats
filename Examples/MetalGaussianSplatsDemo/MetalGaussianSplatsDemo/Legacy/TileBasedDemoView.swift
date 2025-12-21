// swiftlint:disable indentation_width
// TODO: TileBasedDemoView needs to be updated to use SplatCloudDescriptor.loadGPUSplatCloud()
// Commented out until tile-based rendering is integrated into SplatDocumentRenderView

/*
 #if !arch(x86_64)
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

 @State private var splatCloud: GPUSplatCloud<SparkSplat>?
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
 HeatMapLegend(maxCount: resources.readTileCounts().max() ?? 0)
 .padding()
 .id(statsUpdateCounter)
 }
 }
 .onChange(of: url, initial: true) {
 Task {
 loadGPUSplatCloud()
 }
 }
 }

 private func loadGPUSplatCloud() {
 guard let url else {
 return
 }
 splatCloud = try! GPUSplatCloud(url: url, cameraMatrix: cameraMatrix)
 }
 }

 #endif
 */
// swiftlint:enable indentation_width

#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI
internal import os
import SwiftUI
import UniformTypeIdentifiers

enum RendererType: String, CaseIterable, Identifiable {
    case antimatter15 = "Antimatter15"
    case spark = "Spark"
    case stochastic = "Stochastic (Experimental)"

    var id: String { rawValue }
}

public struct GaussianSplatDemoView: View {
    @State private var rendererType: RendererType = .spark
    @State private var showingRotationPopover = false
    @State private var splatURL: URL?
    @State private var folderURL: URL?
    @State private var folderSplatFiles: [URL] = []

    @AppStorage("folderBookmark") private var folderBookmarkData: Data?

    // Shared camera & transform
    @State private var projection: any ProjectionProtocol = PerspectiveProjection()
    @State private var cameraMatrix: simd_float4x4 = .init(translation: [0, 0.5, 1.5])
    @State private var modelMatrix: simd_float4x4 = .identity
    @State private var rotationX = Float.pi
    @State private var rotationY: Float = 0
    @State private var rotationZ: Float = 0
    @State private var splatCount: Int?

    public init() {
        // This line intentionally left blank.
    }

    public var body: some View {
        NavigationSplitView {
            SplatSidebarView(
                splatURL: $splatURL,
                folderURL: $folderURL,
                folderSplatFiles: $folderSplatFiles,
                folderBookmarkData: $folderBookmarkData
            )
        } detail: {
            ZStack {
                Color.black
                WorldView(projection: $projection, cameraMatrix: $cameraMatrix) {
                    switch rendererType {
                    case .antimatter15:
                        Antimatter15RendererView(
                            url: splatURL,
                            projection: projection,
                            cameraMatrix: cameraMatrix,
                            modelMatrix: modelMatrix
                        )

                    case .spark:
                        SparkRendererView(
                            url: splatURL,
                            projection: projection,
                            cameraMatrix: cameraMatrix,
                            modelMatrix: modelMatrix
                        )

                    case .stochastic:
                        StochasticRendererView(
                            url: splatURL,
                            projection: projection,
                            cameraMatrix: cameraMatrix,
                            modelMatrix: modelMatrix
                        )
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    let camPos = SIMD3<Float>(cameraMatrix.columns.3.x, cameraMatrix.columns.3.y, cameraMatrix.columns.3.z)
                    let modelPos = SIMD3<Float>(modelMatrix.columns.3.x, modelMatrix.columns.3.y, modelMatrix.columns.3.z)
                    let fileName = splatURL?.lastPathComponent ?? "No file"

                    Text("""
                    Renderer: \(rendererType.rawValue)
                    File: \(fileName)
                    Splats: \(splatCount.map { $0.formatted() } ?? "—")
                    Camera: (\(String(format: "%.2f", camPos.x)), \(String(format: "%.2f", camPos.y)), \(String(format: "%.2f", camPos.z)))
                    Model: (\(String(format: "%.2f", modelPos.x)), \(String(format: "%.2f", modelPos.y)), \(String(format: "%.2f", modelPos.z)))
                    """)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
            .toolbar {
                toolbar
            }
        }
        .onChange(of: rotationX, initial: true) {
            updateModelMatrix()
        }
        .onChange(of: rotationY, initial: true) {
            updateModelMatrix()
        }
        .onChange(of: rotationZ, initial: true) {
            updateModelMatrix()
        }
        .onAppear {
            if splatURL == nil {
                splatURL = Bundle.main.url(forResource: "centered_lastchance", withExtension: "splat")
            }
            restoreFolderFromBookmark()
        }
        .onChange(of: splatURL, initial: true) {
            if let url = splatURL {
                splatCount = try? SplatCloud<SparkGPUSplat>.splatCount(from: url)
            } else {
                splatCount = nil
            }
        }
    }

    private func restoreFolderFromBookmark() {
        guard let bookmarkData = folderBookmarkData, let path = String(data: bookmarkData, encoding: .utf8) else {
            return
        }

        let url = URL(fileURLWithPath: path)
        folderURL = url
        scanFolder(url)
    }

    private func scanFolder(_ url: URL) {
        let fileManager = FileManager.default
        let extensions = ["ply", "splat", "spz"]

        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            folderSplatFiles = contents.filter { file in
                extensions.contains(file.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            print("Missing folder")
        }
    }

    func updateModelMatrix() {
        let rotX = float4x4(xRotation: .radians(rotationX))
        let rotY = float4x4(yRotation: .radians(rotationY))
        let rotZ = float4x4(zRotation: .radians(rotationZ))
        modelMatrix = rotZ * rotY * rotX
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItem(id: "renderer") {
            Picker("Renderer", selection: $rendererType) {
                ForEach(RendererType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
        }

        ToolbarItem {
            Button("Adjust Axes") {
                showingRotationPopover = true
            }
            .popover(isPresented: $showingRotationPopover) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Adjust Coordinate Axes")
                        .font(.headline)

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
                }
                .padding()
                .frame(minWidth: 250)
            }
        }
    }
}

#endif

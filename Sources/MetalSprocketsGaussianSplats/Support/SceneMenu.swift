#if os(iOS) || (os(macOS) && !arch(x86_64))
import simd
import SwiftUI

/// A toolbar menu for saving and restoring scenes (camera, splat file, and axis settings)
public struct SceneMenu: View {
    @Binding var cameraMatrix: simd_float4x4
    @Binding var splatURL: URL?
    @Binding var rotationX: Float
    @Binding var rotationY: Float
    @Binding var rotationZ: Float

    private var sceneStore: SceneStore

    @State private var showingSaveSheet = false
    @State private var newSceneName = ""

    public init(
        cameraMatrix: Binding<simd_float4x4>,
        splatURL: Binding<URL?>,
        rotationX: Binding<Float>,
        rotationY: Binding<Float>,
        rotationZ: Binding<Float>,
        sceneStore: SceneStore = .shared
    ) {
        self._cameraMatrix = cameraMatrix
        self._splatURL = splatURL
        self._rotationX = rotationX
        self._rotationY = rotationY
        self._rotationZ = rotationZ
        self.sceneStore = sceneStore
    }

    public var body: some View {
        Menu {
            Button {
                showingSaveSheet = true
            } label: {
                Label("Save Scene", systemImage: "square.and.arrow.down")
            }

            if !sceneStore.savedScenes.isEmpty {
                Divider()

                ForEach(sceneStore.savedScenes) { scene in
                    Button {
                        restoreScene(scene)
                    } label: {
                        VStack(alignment: .leading) {
                            Label(scene.name, systemImage: "doc.viewfinder")
                        }
                    }
                }

                Divider()

                Button(role: .destructive) {
                    sceneStore.clearAll()
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
            }
        } label: {
            Label("Scene", systemImage: "doc.viewfinder")
        }
        .sheet(isPresented: $showingSaveSheet, onDismiss: {
            newSceneName = ""
        }) {
            saveSceneSheet
                .onAppear {
                    newSceneName = defaultSceneName
                }
        }
    }

    private var defaultSceneName: String {
        let baseName = splatURL?.deletingPathExtension().lastPathComponent ?? "Scene"
        return "\(baseName) \(sceneStore.savedScenes.count + 1)"
    }

    private func restoreScene(_ scene: SavedScene) {
        cameraMatrix = scene.cameraMatrix
        splatURL = scene.splatURL
        rotationX = scene.axisSettings.rotationX
        rotationY = scene.axisSettings.rotationY
        rotationZ = scene.axisSettings.rotationZ
    }

    @ViewBuilder
    private var saveSceneSheet: some View {
        VStack(spacing: 16) {
            Text("Save Scene")
                .font(.headline)

            TextField("Scene Name", text: $newSceneName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    showingSaveSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    let axisSettings = AxisSettings(
                        rotationX: rotationX,
                        rotationY: rotationY,
                        rotationZ: rotationZ
                    )
                    sceneStore.saveScene(
                        name: newSceneName,
                        cameraMatrix: cameraMatrix,
                        splatURL: splatURL,
                        axisSettings: axisSettings
                    )
                    showingSaveSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func formatRotation(_ radians: Float) -> String {
        let degrees = radians * 180 / .pi
        return "\(Int(degrees.rounded()))°"
    }
}

/// Toolbar content builder for adding scene menu to toolbars
public struct SceneMenuToolbarContent: ToolbarContent {
    @Binding var cameraMatrix: simd_float4x4
    @Binding var splatURL: URL?
    @Binding var rotationX: Float
    @Binding var rotationY: Float
    @Binding var rotationZ: Float

    private var sceneStore: SceneStore

    public init(
        cameraMatrix: Binding<simd_float4x4>,
        splatURL: Binding<URL?>,
        rotationX: Binding<Float>,
        rotationY: Binding<Float>,
        rotationZ: Binding<Float>,
        sceneStore: SceneStore = .shared
    ) {
        self._cameraMatrix = cameraMatrix
        self._splatURL = splatURL
        self._rotationX = rotationX
        self._rotationY = rotationY
        self._rotationZ = rotationZ
        self.sceneStore = sceneStore
    }

    public var body: some ToolbarContent {
        ToolbarItem(id: "scene-menu") {
            SceneMenu(
                cameraMatrix: $cameraMatrix,
                splatURL: $splatURL,
                rotationX: $rotationX,
                rotationY: $rotationY,
                rotationZ: $rotationZ,
                sceneStore: sceneStore
            )
        }
    }
}
#endif

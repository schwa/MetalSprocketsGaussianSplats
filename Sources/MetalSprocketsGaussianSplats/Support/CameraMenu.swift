#if os(iOS) || (os(macOS) && !arch(x86_64))
import simd
import SwiftUI

/// A toolbar menu for saving and restoring camera positions
public struct CameraMenu: View {
    @Binding var cameraMatrix: simd_float4x4
    private var cameraStore: CameraStore

    @State private var showingSaveSheet = false
    @State private var newCameraName = ""

    public init(cameraMatrix: Binding<simd_float4x4>, cameraStore: CameraStore = .shared) {
        self._cameraMatrix = cameraMatrix
        self.cameraStore = cameraStore
    }

    public var body: some View {
        Menu {
            Button {
                showingSaveSheet = true
            } label: {
                Label("Save Camera", systemImage: "camera.badge.plus")
            }

            if !cameraStore.savedCameras.isEmpty {
                Divider()

                ForEach(cameraStore.savedCameras) { camera in
                    Button {
                        cameraMatrix = camera.matrix
                    } label: {
                        Label(camera.name, systemImage: "camera")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    cameraStore.clearAll()
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
            }
        } label: {
            Label("Camera", systemImage: "camera")
        }
        .sheet(isPresented: $showingSaveSheet) {
            saveCameraSheet
        }
    }

    @ViewBuilder
    private var saveCameraSheet: some View {
        NavigationStack {
            Form {
                TextField("Camera Name", text: $newCameraName)
            }
            .navigationTitle("Save Camera")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        newCameraName = ""
                        showingSaveSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = newCameraName.isEmpty ? "Camera \(cameraStore.savedCameras.count + 1)" : newCameraName
                        cameraStore.saveCamera(name: name, matrix: cameraMatrix)
                        newCameraName = ""
                        showingSaveSheet = false
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 120)
        #endif
    }
}

/// Toolbar content builder for adding camera menu to toolbars
public struct CameraMenuToolbarContent: ToolbarContent {
    @Binding var cameraMatrix: simd_float4x4
    private var cameraStore: CameraStore

    public init(cameraMatrix: Binding<simd_float4x4>, cameraStore: CameraStore = .shared) {
        self._cameraMatrix = cameraMatrix
        self.cameraStore = cameraStore
    }

    public var body: some ToolbarContent {
        ToolbarItem(id: "camera-menu") {
            CameraMenu(cameraMatrix: $cameraMatrix, cameraStore: cameraStore)
        }
    }
}
#endif

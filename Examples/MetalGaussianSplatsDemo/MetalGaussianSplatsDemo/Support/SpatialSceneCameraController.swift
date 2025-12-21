import GeometryLite3D
import simd
import SwiftUI

/// A camera controller for spatial scenes that uses pan and zoom gestures.
/// Unlike the turntable controller, this moves both the camera position and target together.
struct SpatialSceneCameraController: ViewModifier {
    @Binding var transform: simd_float4x4

    @State private var cameraX: Float = 0
    @State private var cameraY: Float = 0
    @State private var cameraDistance: Float = 1
    @State private var dragStart: SIMD2<Float> = .zero
    @State private var magnifyStart: Float = 1

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let sensitivity: Float = 0.001
                        let dx = Float(value.translation.width) * sensitivity
                        let dy = Float(-value.translation.height) * sensitivity
                        cameraX = dragStart.x + dx
                        cameraY = dragStart.y + dy
                        updateCamera()
                    }
                    .onEnded { _ in
                        dragStart = SIMD2<Float>(cameraX, cameraY)
                    }
            )
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let newDistance = magnifyStart / Float(value.magnification)
                        cameraDistance = max(0.1, min(5.0, newDistance))
                        updateCamera()
                    }
                    .onEnded { _ in
                        magnifyStart = cameraDistance
                    }
            )
            .onAppear {
                // Extract initial distance from transform
                cameraDistance = transform.columns.3.z
                magnifyStart = cameraDistance
            }
    }

    private func updateCamera() {
        // Pan camera - both position and target move together
        transform = LookAt(
            position: [cameraX, cameraY, cameraDistance],
            target: [cameraX, cameraY, 0],
            up: [0, 1, 0]
        ).cameraMatrix
    }
}

import GeometryLite3D
import simd
import SwiftUI

/// A camera controller for room navigation mode.
/// The camera stays at a fixed height (Y position) and can only look around (yaw/pitch) via drag gestures.
/// Movement is via WASD keys on a flat plane.
struct RoomCameraController: ViewModifier {
    @Binding var cameraMatrix: simd_float4x4

    /// Fixed camera height (Y position)
    var cameraHeight: Float = 0

    // Camera orientation state
    @State private var cameraYaw: Float = 0
    @State private var cameraPitch: Float = 0
    @State private var cameraPosition: SIMD3<Float> = .zero

    // Drag gesture state
    @State private var dragStartYaw: Float = 0
    @State private var dragStartPitch: Float = 0
    @State private var isDragging = false

    // Pitch animation
    @State private var pitchAnimationTimer: Timer?

    // Movement speed
    private let moveSpeed: Float = 0.1

    func body(content: Content) -> some View {
        content
            .focusable()
            .gesture(lookGesture)
            .onKeyPress("w") { moveCamera(z: moveSpeed); return .handled }
            .onKeyPress("s") { moveCamera(z: -moveSpeed); return .handled }
            .onKeyPress("a") { moveCamera(x: moveSpeed); return .handled }
            .onKeyPress("d") { moveCamera(x: -moveSpeed); return .handled }
            .onKeyPress(.upArrow) { moveCamera(z: -moveSpeed); return .handled }
            .onKeyPress(.downArrow) { moveCamera(z: moveSpeed); return .handled }
            .onKeyPress(.leftArrow) { rotateCamera(yaw: -.pi / 36); return .handled }  // 5 degrees
            .onKeyPress(.rightArrow) { rotateCamera(yaw: .pi / 36); return .handled }
            .onAppear {
                initializeFromMatrix()
            }
    }

    private func initializeFromMatrix() {
        // Extract position from the camera matrix
        cameraPosition = SIMD3<Float>(cameraMatrix.columns.3.x, cameraHeight, cameraMatrix.columns.3.z)

        // Extract yaw from the camera matrix (rotation around Y axis)
        // The camera looks down -Z in its local space, so we extract the yaw from the matrix
        let forward = -SIMD3<Float>(cameraMatrix.columns.2.x, 0, cameraMatrix.columns.2.z)
        if length(forward) > 0.001 {
            cameraYaw = atan2(forward.x, -forward.z)
        }

        dragStartYaw = cameraYaw
        dragStartPitch = cameraPitch
    }

    private var lookGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Capture start values on first change
                if !isDragging {
                    isDragging = true
                    dragStartYaw = cameraYaw
                    dragStartPitch = cameraPitch
                }

                pitchAnimationTimer?.invalidate()
                pitchAnimationTimer = nil

                let sensitivity: Float = 0.005
                let dx = Float(value.translation.width) * sensitivity
                let dy = Float(value.translation.height) * sensitivity

                cameraYaw = dragStartYaw - dx
                cameraPitch = max(-.pi / 2 + 0.1, min(.pi / 2 - 0.1, dragStartPitch - dy))

                updateCameraMatrix()
            }
            .onEnded { _ in
                isDragging = false
                dragStartYaw = cameraYaw
                dragStartPitch = cameraPitch
                animatePitchToHorizontal()
            }
    }

    private func moveCamera(x: Float = 0, z: Float = 0) {
        // Move relative to camera's current yaw orientation
        let sinYaw = sin(cameraYaw)
        let cosYaw = cos(cameraYaw)

        // Forward is -Z in camera space, right is +X
        let forward = SIMD3<Float>(-sinYaw, 0, -cosYaw)
        let right = SIMD3<Float>(cosYaw, 0, -sinYaw)

        cameraPosition += forward * z + right * x
        cameraPosition.y = cameraHeight  // Keep height fixed

        updateCameraMatrix()
    }

    private func rotateCamera(yaw: Float) {
        cameraYaw += yaw
        dragStartYaw = cameraYaw
        updateCameraMatrix()
    }

    private func updateCameraMatrix() {
        // Build rotation from yaw and pitch
        let yawQuat = simd_quatf(angle: cameraYaw, axis: SIMD3<Float>(0, 1, 0))
        let pitchQuat = simd_quatf(angle: cameraPitch, axis: SIMD3<Float>(1, 0, 0))
        let rotation = yawQuat * pitchQuat

        // Build camera matrix
        var matrix = simd_float4x4(rotation)
        matrix.columns.3 = SIMD4<Float>(cameraPosition, 1)

        cameraMatrix = matrix
    }

    private func animatePitchToHorizontal() {
        pitchAnimationTimer?.invalidate()

        let startPitch = cameraPitch
        let targetPitch: Float = 0
        let duration: Double = 0.2
        let startTime = Date()

        pitchAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            MainActor.assumeIsolated {
                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(elapsed / duration, 1.0)

                let t = 1.0 - pow(1.0 - progress, 3)
                cameraPitch = startPitch + (targetPitch - startPitch) * Float(t)

                updateCameraMatrix()

                if progress >= 1.0 {
                    timer.invalidate()
                    pitchAnimationTimer = nil
                    dragStartPitch = 0
                }
            }
        }
    }
}

extension View {
    func roomCameraController(cameraMatrix: Binding<simd_float4x4>, cameraHeight: Float = 0) -> some View {
        modifier(RoomCameraController(cameraMatrix: cameraMatrix, cameraHeight: cameraHeight))
    }
}

#if os(iOS) || os(macOS)
import GeometryLite3D
import simd
import SwiftUI

struct CameraInspector: View {
    @Binding var cameraMode: CameraMode
    @Binding var zoomToFit: Bool
    @Binding var verticalAngleOfView: Double
    @Binding var cameraMatrix: simd_float4x4
    var viewSize: CGSize
    var zoomToFitDisabled: Bool = false
    var boundsCenter: SIMD3<Float> = .zero
    var boundsSize: SIMD3<Float> = .zero
    var teleportDisabled: Bool = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Section("Camera") {
            Picker("Mode", selection: $cameraMode) {
                ForEach(CameraMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Zoom to Fit", isOn: $zoomToFit)
                .disabled(cameraMode != .object || zoomToFitDisabled)

            Button("Teleport to Center") {
                teleportToCenter()
            }
            .disabled(teleportDisabled)
        }

        cameraTransformSection

        Section("Field of View") {
            Slider(value: $verticalAngleOfView, in: 30...120) {
                Text("FOV")
            }
            LabeledContent("FOV", value: "\(Int(verticalAngleOfView))°")
        }

        viewportSection
    }

    private func teleportToCenter() {
        cameraMatrix = simd_float4x4(translation: boundsCenter)
    }

    @ViewBuilder
    private var cameraTransformSection: some View {
        let position = cameraPosition
        let rotation = cameraRotationDegrees

        Section("Position") {
            LabeledContent("X", value: position.x.formatted(.number.precision(.fractionLength(3))))
                .monospacedDigit()
            LabeledContent("Y", value: position.y.formatted(.number.precision(.fractionLength(3))))
                .monospacedDigit()
            LabeledContent("Z", value: position.z.formatted(.number.precision(.fractionLength(3))))
                .monospacedDigit()
        }
        .animation(nil, value: position)

        Section("Rotation") {
            LabeledContent("Pitch", value: rotation.x.formatted(.number.precision(.fractionLength(1))) + "°")
                .monospacedDigit()
            LabeledContent("Yaw", value: rotation.y.formatted(.number.precision(.fractionLength(1))) + "°")
                .monospacedDigit()
            LabeledContent("Roll", value: rotation.z.formatted(.number.precision(.fractionLength(1))) + "°")
                .monospacedDigit()
        }
        .animation(nil, value: rotation)
    }

    private var cameraPosition: SIMD3<Float> {
        SIMD3<Float>(cameraMatrix.columns.3.x, cameraMatrix.columns.3.y, cameraMatrix.columns.3.z)
    }

    private var cameraRotationDegrees: SIMD3<Float> {
        let m = cameraMatrix
        let pitch = asin(-m.columns.2.y)
        let yaw: Float
        let roll: Float

        if cos(pitch) > 0.0001 {
            yaw = atan2(m.columns.2.x, m.columns.2.z)
            roll = atan2(m.columns.0.y, m.columns.1.y)
        } else {
            yaw = atan2(-m.columns.0.z, m.columns.0.x)
            roll = 0
        }

        let toDegrees: Float = 180.0 / .pi
        return SIMD3<Float>(pitch * toDegrees, yaw * toDegrees, roll * toDegrees)
    }

    @ViewBuilder
    private var viewportSection: some View {
        Section("Viewport") {
            LabeledContent("Size", value: "\(formattedDimension(viewSize.width)) × \(formattedDimension(viewSize.height))")
            LabeledContent("Aspect Ratio", value: aspectRatioString(for: viewSize))
            LabeledContent("Megapixels", value: megapixelsString(for: viewSize))
            if displayScale != 1 {
                LabeledContent("Scale", value: "\(Int(displayScale))x")
            }
        }
    }

    private func aspectRatioString(for size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else {
            return "—"
        }
        let ratio = Double(size.width / size.height)
        return ratio.formatted(.number.precision(.fractionLength(2))) + ":1"
    }

    private func megapixelsString(for size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else {
            return "—"
        }
        let pixels = size.width * displayScale * size.height * displayScale
        let megapixels = Double(pixels / 1_000_000)
        return megapixels.formatted(.number.precision(.fractionLength(2))) + " MP"
    }

    private func formattedDimension(_ value: CGFloat) -> String {
        let pts = Int(value)
        if displayScale == 1 {
            return "\(pts)"
        }
        let px = Int(value * displayScale)
        return "\(pts) (\(px))"
    }
}
#endif

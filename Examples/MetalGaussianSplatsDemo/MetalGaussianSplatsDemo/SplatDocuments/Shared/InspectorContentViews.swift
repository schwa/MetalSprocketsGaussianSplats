#if os(iOS) || os(macOS)
import GeometryLite3D
import MetalSprocketsGaussianSplats
import simd
import SwiftUI

// MARK: - Shared Cloud Inspector Components

/// Rotation section - shared between single and multi mode
struct RotationSection: View {
    let title: String
    @Binding var rotationX: Float
    @Binding var rotationY: Float
    @Binding var rotationZ: Float

    init(_ title: String = "Rotation", rotationX: Binding<Float>, rotationY: Binding<Float>, rotationZ: Binding<Float>) {
        self.title = title
        self._rotationX = rotationX
        self._rotationY = rotationY
        self._rotationZ = rotationZ
    }

    var body: some View {
        Section(title) {
            RotationPicker(label: "Rotate X", value: $rotationX)
            RotationPicker(label: "Rotate Y", value: $rotationY)
            RotationPicker(label: "Rotate Z", value: $rotationZ)
        }
    }
}

/// Cloud properties section (name, enabled, opacity) - multi mode only
struct CloudPropertiesSection: View {
    @Binding var displayName: String?
    @Binding var enabled: Bool
    @Binding var opacity: Float

    var body: some View {
        Section("Cloud") {
            TextField("Name", text: Binding(
                get: { displayName ?? "" },
                set: { displayName = $0.isEmpty ? nil : $0 }
            ))

            Toggle("Enabled", isOn: $enabled)

            VStack(alignment: .leading) {
                HStack {
                    Text("Opacity")
                    Spacer()
                    Text("\(Int(opacity * 100))%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $opacity, in: 0...1)
            }
        }
    }
}

/// Translation section - multi mode only
struct TranslationSection: View {
    @Binding var transform: Transform

    var body: some View {
        Section("Position") {
            TransformEditor(transform: $transform)
        }
    }
}

/// Center model section - single mode only
struct CenterModelSection: View {
    @Binding var centerModel: Bool

    var body: some View {
        Section("Model Transform") {
            Toggle("Center Model", isOn: $centerModel)
        }
    }
}

/// Delete cloud section - multi mode only
struct DeleteCloudSection: View {
    let onDelete: () -> Void

    var body: some View {
        Section {
            Button(role: .destructive, action: onDelete) {
                Label("Remove Cloud", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Unified Cloud Inspector

/// Shows cloud information - unified with composable sections
struct UnifiedCloudInfoContent: View {
    // Splat info
    var descriptor: SplatCloudDescriptor?

    // Rotation (both modes)
    @Binding var rotationX: Float
    @Binding var rotationY: Float
    @Binding var rotationZ: Float
    var rotationSectionTitle: String = "Rotation"

    // Single mode: center model
    @Binding var centerModel: Bool
    var showCenterModel: Bool = false

    // Multi mode: cloud properties
    @Binding var displayName: String?
    @Binding var enabled: Bool
    @Binding var opacity: Float
    var showCloudProperties: Bool = false

    // Multi mode: translation
    @Binding var transform: Transform
    var showTranslation: Bool = false

    // Multi mode: delete
    var onDelete: (() -> Void)?

    var body: some View {
        // Cloud properties (multi mode)
        if showCloudProperties {
            CloudPropertiesSection(
                displayName: $displayName,
                enabled: $enabled,
                opacity: $opacity
            )
        }

        // Translation (multi mode)
        if showTranslation {
            TranslationSection(transform: $transform)
        }

        // Center model (single mode)
        if showCenterModel {
            CenterModelSection(centerModel: $centerModel)
        }

        // Rotation (both modes)
        RotationSection(
            rotationSectionTitle,
            rotationX: $rotationX,
            rotationY: $rotationY,
            rotationZ: $rotationZ
        )

        // Splat info (both modes)
        SplatCloudInfoSections(descriptor: descriptor)

        // Delete (multi mode)
        if let onDelete {
            DeleteCloudSection(onDelete: onDelete)
        }
    }
}

// MARK: - Unified Camera Inspector

/// Shows camera and viewport settings - unified for both single and multi mode
struct UnifiedCameraContent: View {
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
        // Position camera at bounds center, looking forward (-Z)
        cameraMatrix = simd_float4x4(translation: boundsCenter)
    }

    @ViewBuilder
    private var cameraTransformSection: some View {
        let position = cameraPosition
        let rotation = cameraRotationDegrees

        Section("Position") {
            LabeledContent("X", value: String(format: "%.3f", position.x))
                .monospacedDigit()
            LabeledContent("Y", value: String(format: "%.3f", position.y))
                .monospacedDigit()
            LabeledContent("Z", value: String(format: "%.3f", position.z))
                .monospacedDigit()
        }
        .animation(nil, value: position)

        Section("Rotation") {
            LabeledContent("Pitch", value: String(format: "%.1f°", rotation.x))
                .monospacedDigit()
            LabeledContent("Yaw", value: String(format: "%.1f°", rotation.y))
                .monospacedDigit()
            LabeledContent("Roll", value: String(format: "%.1f°", rotation.z))
                .monospacedDigit()
        }
        .animation(nil, value: rotation)
    }

    /// Extract camera position from the matrix
    private var cameraPosition: SIMD3<Float> {
        SIMD3<Float>(cameraMatrix.columns.3.x, cameraMatrix.columns.3.y, cameraMatrix.columns.3.z)
    }

    /// Extract camera rotation as Euler angles in degrees (pitch, yaw, roll)
    private var cameraRotationDegrees: SIMD3<Float> {
        // Extract rotation matrix (upper-left 3x3)
        let m = cameraMatrix

        // Extract Euler angles (assuming YXZ order: yaw, pitch, roll)
        let pitch = asin(-m.columns.2.y)
        let yaw: Float
        let roll: Float

        if cos(pitch) > 0.0001 {
            yaw = atan2(m.columns.2.x, m.columns.2.z)
            roll = atan2(m.columns.0.y, m.columns.1.y)
        } else {
            // Gimbal lock
            yaw = atan2(-m.columns.0.z, m.columns.0.x)
            roll = 0
        }

        // Convert to degrees
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
        let ratio = size.width / size.height
        return String(format: "%.2f:1", ratio)
    }

    private func megapixelsString(for size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else {
            return "—"
        }
        let pixels = size.width * displayScale * size.height * displayScale
        let megapixels = pixels / 1_000_000
        return String(format: "%.2f MP", megapixels)
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

// MARK: - Unified Render Inspector

/// Shows render settings - unified for both single and multi mode
struct UnifiedRenderContent<CullingContent: View>: View {
    @Binding var backgroundColor: Color
    @Binding var useSphericalHarmonics: Bool
    var sphericalHarmonicsDisabled: Bool = false
    var sphericalHarmonicsWarning: String?
    @Binding var showBoundingBoxes: Bool
    @Binding var debugModeEnabled: Bool
    @Binding var debugMode: SplatDebugMode
    var lastSortEvent: SortEvent?
    var onScreenshot: (() -> Void)?
    @ViewBuilder var cullingContent: () -> CullingContent

    var body: some View {
        Section("Renderer") {
            LabeledContent("Type", value: "Spark")
            ColorPicker("Background", selection: $backgroundColor)
            Toggle("Spherical Harmonics", isOn: $useSphericalHarmonics)
                .disabled(sphericalHarmonicsDisabled || debugModeEnabled)

            if let warning = sphericalHarmonicsWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Show Bounding Boxes", isOn: $showBoundingBoxes)
        }

        if let sortEvent = lastSortEvent {
            Section("Sort Statistics") {
                LabeledContent("Duration") {
                    Text(String(format: "%.2f ms", sortEvent.duration * 1_000))
                        .monospacedDigit()
                }
                LabeledContent("Splats") {
                    Text(sortEvent.splatCount.formatted())
                        .monospacedDigit()
                }
                LabeledContent("Clouds") {
                    Text("\(sortEvent.cloudCount)")
                        .monospacedDigit()
                }
                LabeledContent("Time Since Sort") {
                    TimeSinceSortView(sortTime: sortEvent.time)
                }
            }
        }

        Section("Debug Visualization") {
            Toggle("Enable Debug Mode", isOn: $debugModeEnabled)

            if debugModeEnabled {
                Picker("Mode", selection: $debugMode) {
                    ForEach(SplatDebugMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text(debugMode.colorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        cullingContent()

        if let onScreenshot {
            Section("Export") {
                Button("Take Screenshot", systemImage: "camera") {
                    onScreenshot()
                }
            }
        }
    }
}

// MARK: - Culling Section Views

/// Culling section for single mode (normalized 0-1 bounds)
struct NormalizedCullingSection: View {
    @Binding var enabled: Bool
    @Binding var minBounds: SIMD3<Float>
    @Binding var maxBounds: SIMD3<Float>
    var disabled: Bool = false

    var body: some View {
        Section("Culling Bounding Box") {
            Toggle("Enable Culling", isOn: $enabled)
                .disabled(disabled)

            if enabled {
                NormalizedBoundsSlider(label: "Min X", value: $minBounds.x)
                NormalizedBoundsSlider(label: "Min Y", value: $minBounds.y)
                NormalizedBoundsSlider(label: "Min Z", value: $minBounds.z)
                NormalizedBoundsSlider(label: "Max X", value: $maxBounds.x)
                NormalizedBoundsSlider(label: "Max Y", value: $maxBounds.y)
                NormalizedBoundsSlider(label: "Max Z", value: $maxBounds.z)
            }
        }
    }
}

/// Culling section for multi mode (absolute world-space bounds)
struct AbsoluteCullingSection: View {
    @Binding var enabled: Bool
    @Binding var minBounds: SIMD3<Float>
    @Binding var maxBounds: SIMD3<Float>
    var range: ClosedRange<Float> = -20...20

    var body: some View {
        Section("Culling Bounding Box") {
            Toggle("Enable Culling", isOn: $enabled)

            if enabled {
                AbsoluteBoundsSlider(label: "Min X", value: $minBounds.x, range: range)
                AbsoluteBoundsSlider(label: "Min Y", value: $minBounds.y, range: range)
                AbsoluteBoundsSlider(label: "Min Z", value: $minBounds.z, range: range)
                AbsoluteBoundsSlider(label: "Max X", value: $maxBounds.x, range: range)
                AbsoluteBoundsSlider(label: "Max Y", value: $maxBounds.y, range: range)
                AbsoluteBoundsSlider(label: "Max Z", value: $maxBounds.z, range: range)
            }
        }
    }
}

// MARK: - Scene Inspector (Multi-mode only)

struct SceneInspectorContent: View {
    @Binding var document: SplatSceneDocument
    @Environment(UnifiedSplatViewModel.self) private var viewModel

    private var enabledSplatCount: Int {
        let enabledCloudIDs = Set(document.scene.clouds.filter(\.enabled).map(\.id))
        return viewModel.loadedClouds
            .filter { enabledCloudIDs.contains($0.id) }
            .reduce(into: 0) { $0 += $1.cloud?.count ?? 0 }
    }

    var body: some View {
        Section("Scene") {
            LabeledContent("Clouds", value: "\(document.scene.clouds.count)")
            LabeledContent("Enabled", value: "\(document.scene.clouds.filter(\.enabled).count)")
            LabeledContent("Splats", value: "\(enabledSplatCount.formatted())")
        }

        Section("Scene Transform") {
            TransformEditor(transform: $document.scene.sceneTransform)
        }

        Section("Scene Orientation") {
            RotationPicker(label: "Rotate X", value: $document.scene.sceneTransform.rotation.x)
            RotationPicker(label: "Rotate Y", value: $document.scene.sceneTransform.rotation.y)
            RotationPicker(label: "Rotate Z", value: $document.scene.sceneTransform.rotation.z)
        }
    }
}

// MARK: - Helper Views

private struct NormalizedBoundsSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0...1)
        }
    }
}

private struct AbsoluteBoundsSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Time Since Sort View

/// Displays time since last sort, auto-updating
private struct TimeSinceSortView: View {
    let sortTime: Date

    @State private var timeSince: TimeInterval = 0

    var body: some View {
        Text(formatTimeSince(timeSince))
            .monospacedDigit()
            .task(id: sortTime) {
                while !Task.isCancelled {
                    timeSince = Date().timeIntervalSince(sortTime)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
    }

    private func formatTimeSince(_ interval: TimeInterval) -> String {
        if interval < 1 {
            return String(format: "%.0f ms", interval * 1000)
        } else if interval < 60 {
            return String(format: "%.1f s", interval)
        } else {
            return String(format: "%.0f s", interval)
        }
    }
}
#endif

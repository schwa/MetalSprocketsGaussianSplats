#if os(iOS) || os(macOS)
import simd
import SwiftUI

// MARK: - Shared Types

struct BoundingBoxInfo: Identifiable {
    let id: UUID
    let bounds: BoundingBox
    let modelMatrix: simd_float4x4
    let color: Color
}

// MARK: - Bounding Box Wireframe

/// Draws wireframe edges for bounding boxes
struct BoundingBoxWireframe: View {
    let boundingBoxes: [BoundingBoxInfo]
    let viewMatrix: simd_float4x4
    let projectionMatrix: simd_float4x4
    let viewportSize: CGSize

    var body: some View {
        Canvas { context, _ in
            for box in boundingBoxes {
                drawWireframe(context: context, box: box)
            }
        }
        .allowsHitTesting(false)
    }

    // Face definitions for back-face culling
    private static let faceDefinitions: [[Int]] = [
        [0, 1, 3, 2], // bottom
        [4, 6, 7, 5], // top
        [0, 2, 6, 4], // left
        [1, 5, 7, 3], // right
        [0, 4, 5, 1], // front
        [2, 3, 7, 6] // back
    ]

    private func drawWireframe(context: GraphicsContext, box: BoundingBoxInfo) {
        let corners = box.bounds.corners
        let mv = viewMatrix * box.modelMatrix
        let mvp = projectionMatrix * mv

        let viewCorners: [SIMD3<Float>] = corners.map { corner in
            let p = mv * SIMD4<Float>(corner, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }

        let screenPoints: [CGPoint?] = corners.map { corner in
            projectToScreen(point: corner, mvp: mvp)
        }

        // Compute front-facing for each face
        var frontFacing = [Bool](repeating: false, count: 6)
        for (faceIdx, faceCorners) in Self.faceDefinitions.enumerated() {
            let v0 = viewCorners[faceCorners[0]]
            let v1 = viewCorners[faceCorners[1]]
            let v2 = viewCorners[faceCorners[2]]
            let v3 = viewCorners[faceCorners[3]]

            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let normal = cross(edge1, edge2)
            let center = (v0 + v1 + v2 + v3) / 4

            frontFacing[faceIdx] = dot(normal, -center) > 0
        }

        // Edge definitions: (v1, v2, face1, face2)
        let edges: [(Int, Int, Int, Int)] = [
            (0, 1, 0, 4), (1, 3, 0, 3), (3, 2, 0, 5), (2, 0, 0, 2),
            (4, 5, 1, 4), (5, 7, 1, 3), (7, 6, 1, 5), (6, 4, 1, 2),
            (0, 4, 2, 4), (1, 5, 3, 4), (2, 6, 2, 5), (3, 7, 3, 5)
        ]

        for (v1, v2, f1, f2) in edges {
            guard let p1 = screenPoints[v1], let p2 = screenPoints[v2] else { continue }

            let isVisible = frontFacing[f1] || frontFacing[f2]
            let opacity = isVisible ? 1.0 : 0.2

            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)

            context.stroke(path, with: .color(box.color.opacity(opacity)), lineWidth: 2)
        }
    }

    private func projectToScreen(point: SIMD3<Float>, mvp: simd_float4x4) -> CGPoint? {
        let p = SIMD4<Float>(point, 1)
        let clip = mvp * p
        guard clip.w > 0 else {
            return nil
        }

        let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        let x = (ndc.x + 1) * 0.5 * Float(viewportSize.width)
        let y = (1 - ndc.y) * 0.5 * Float(viewportSize.height)

        guard x.isFinite, y.isFinite else {
            return nil
        }
        guard x > -1_000, x < Float(viewportSize.width) + 1_000 else {
            return nil
        }
        guard y > -1_000, y < Float(viewportSize.height) + 1_000 else {
            return nil
        }

        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

// MARK: - Bounding Box Face Interaction

/// Interactive faces for dragging along axes
struct BoundingBoxFaceInteraction: View {
    let boundingBoxes: [BoundingBoxInfo]
    let viewMatrix: simd_float4x4
    let projectionMatrix: simd_float4x4
    let viewportSize: CGSize
    var onDragChange: ((UUID, Int, CGSize) -> Void)?
    var onDragEnd: ((UUID) -> Void)?

    private struct FaceInfo: Identifiable {
        let id: String
        let cloudID: UUID
        let points: [CGPoint]
        let color: Color
        let depth: Float
        let axis: Int
        let axisDirectionScreen: CGVector
    }

    private static let faceDefinitions: [(corners: [Int], axis: Int)] = [
        ([0, 1, 3, 2], 1), // bottom - Y
        ([4, 6, 7, 5], 1), // top - Y
        ([0, 2, 6, 4], 0), // left - X
        ([1, 5, 7, 3], 0), // right - X
        ([0, 4, 5, 1], 2), // front - Z
        ([2, 3, 7, 6], 2) // back - Z
    ]

    private static let axisColors: [Color] = [.red, .green, .blue]
    private static let axisVectors: [SIMD3<Float>] = [
        SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)
    ]

    var body: some View {
        let allFaces = boundingBoxes.flatMap { computeFaces(box: $0) }
            .sorted { $0.depth > $1.depth }

        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(allFaces) { face in
                        DraggableFace(
                            points: face.points,
                            color: face.color,
                            axisDirectionScreen: face.axisDirectionScreen,
                            onDragChange: { delta in
                                onDragChange?(face.cloudID, face.axis, delta)
                            },
                            onDragEnd: {
                                onDragEnd?(face.cloudID)
                            }
                        )
                        .zIndex(Double(face.depth))
                    }
                }
            }
            .allowsHitTesting(true)
    }

    private func computeFaces(box: BoundingBoxInfo) -> [FaceInfo] {
        let corners = box.bounds.corners
        let mv = viewMatrix * box.modelMatrix
        let mvp = projectionMatrix * mv

        let viewCorners: [SIMD3<Float>] = corners.map { corner in
            let p = mv * SIMD4<Float>(corner, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }

        let screenPoints: [CGPoint?] = corners.map { corner in
            projectToScreen(point: corner, mvp: mvp)
        }

        // Compute axis directions in screen space
        let center = box.bounds.center
        let axisScreenDirs: [CGVector] = Self.axisVectors.map { axisVec in
            let p0 = projectToScreen(point: center, mvp: mvp) ?? .zero
            let p1 = projectToScreen(point: center + axisVec * 0.1, mvp: mvp) ?? .zero
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            let len = sqrt(dx * dx + dy * dy)
            return len > 0.001 ? CGVector(dx: dx / len, dy: dy / len) : CGVector(dx: 1, dy: 0)
        }

        var faces: [FaceInfo] = []

        for (faceIdx, def) in Self.faceDefinitions.enumerated() {
            let v0 = viewCorners[def.corners[0]]
            let v1 = viewCorners[def.corners[1]]
            let v2 = viewCorners[def.corners[2]]
            let v3 = viewCorners[def.corners[3]]

            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let normal = cross(edge1, edge2)
            let faceCenter = (v0 + v1 + v2 + v3) / 4

            let isFrontFacing = dot(normal, -faceCenter) > 0

            if isFrontFacing {
                let faceScreenPoints = def.corners.compactMap { screenPoints[$0] }
                if faceScreenPoints.count == 4 {
                    faces.append(FaceInfo(
                        id: "\(box.id)-\(faceIdx)",
                        cloudID: box.id,
                        points: faceScreenPoints,
                        color: Self.axisColors[def.axis],
                        depth: faceCenter.z,
                        axis: def.axis,
                        axisDirectionScreen: axisScreenDirs[def.axis]
                    ))
                }
            }
        }

        return faces
    }

    private func projectToScreen(point: SIMD3<Float>, mvp: simd_float4x4) -> CGPoint? {
        let p = SIMD4<Float>(point, 1)
        let clip = mvp * p
        guard clip.w > 0 else {
            return nil
        }

        let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        let x = (ndc.x + 1) * 0.5 * Float(viewportSize.width)
        let y = (1 - ndc.y) * 0.5 * Float(viewportSize.height)

        guard x.isFinite, y.isFinite else {
            return nil
        }
        guard x > -1_000, x < Float(viewportSize.width) + 1_000 else {
            return nil
        }
        guard y > -1_000, y < Float(viewportSize.height) + 1_000 else {
            return nil
        }

        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

// MARK: - Draggable Face

struct DraggableFace: View {
    let points: [CGPoint]
    let color: Color
    let axisDirectionScreen: CGVector
    var onDragChange: ((CGSize) -> Void)?
    var onDragEnd: (() -> Void)?

    @State private var isHovered = false
    @State private var isDragging = false
    @State private var lastTranslation: CGSize = .zero

    private var boundingRect: CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
        else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    private var localPoints: [CGPoint] {
        let rect = boundingRect
        return points.map { CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY) }
    }

    var body: some View {
        let rect = boundingRect
        QuadShape(points: localPoints)
            .fill(color.opacity(isDragging ? 0.7 : (isHovered ? 0.5 : 0)))
            .frame(width: rect.width, height: rect.height)
            .contentShape(QuadShape(points: localPoints))
            .offset(x: rect.minX, y: rect.minY)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        let delta = CGSize(
                            width: value.translation.width - lastTranslation.width,
                            height: value.translation.height - lastTranslation.height
                        )
                        lastTranslation = value.translation

                        let dragVec = CGVector(dx: delta.width, dy: delta.height)
                        let dot = dragVec.dx * axisDirectionScreen.dx + dragVec.dy * axisDirectionScreen.dy
                        let projected = CGSize(width: dot * axisDirectionScreen.dx, height: dot * axisDirectionScreen.dy)
                        onDragChange?(projected)
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastTranslation = .zero
                        onDragEnd?()
                    }
            )
    }
}

// MARK: - Quad Shape

struct QuadShape: Shape {
    let points: [CGPoint]

    func path(in _: CGRect) -> Path {
        guard points.count == 4 else {
            return Path()
        }
        var path = Path()
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        path.addLine(to: points[3])
        path.closeSubpath()
        return path
    }
}
#endif

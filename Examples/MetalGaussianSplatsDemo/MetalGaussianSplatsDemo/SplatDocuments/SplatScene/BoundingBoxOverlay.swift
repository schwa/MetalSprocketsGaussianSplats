#if os(iOS) || os(macOS)
import simd
import SwiftUI

/// Overlay view that draws bounding boxes for splat clouds
struct BoundingBoxOverlay: View {
    let boundingBoxes: [BoundingBoxInfo]
    let viewMatrix: simd_float4x4
    let projectionMatrix: simd_float4x4
    let viewportSize: CGSize
    var onDrag: ((UUID, Int, CGSize) -> Void)? = nil // (cloudID, axis, screenDelta)

    struct BoundingBoxInfo: Identifiable {
        let id: UUID
        let bounds: BoundingBox
        let modelMatrix: simd_float4x4
        let color: Color
    }
    
    struct FaceInfo: Identifiable {
        let id: String
        let cloudID: UUID
        let points: [CGPoint]
        let color: Color
        let depth: Float
        let axis: Int // 0=X, 1=Y, 2=Z
        let axisDirectionScreen: CGVector // axis direction projected to screen space
    }

    var body: some View {
        // Collect all front-facing faces sorted by depth (back to front)
        let allFaces: [FaceInfo] = boundingBoxes.flatMap { box -> [FaceInfo] in
            computeFaces(box: box)
        }.sorted { $0.depth > $1.depth } // back faces first (higher depth = further)
        
        ZStack(alignment: .topLeading) {
            // Face fills with zIndex so front faces get hover priority
            ForEach(allFaces) { face in
                DraggableFace(
                    points: face.points,
                    color: face.color,
                    axisDirectionScreen: face.axisDirectionScreen,
                    onDrag: { delta in
                        onDrag?(face.cloudID, face.axis, delta)
                    }
                )
                .zIndex(Double(face.depth))
            }
            
            // Wireframe edges (on top)
            Canvas { context, size in
                for box in boundingBoxes {
                    drawWireframe(context: context, box: box)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Face Computation
    
    // Face definitions: corners and axis
    // 0=bottom(Y-), 1=top(Y+), 2=left(X-), 3=right(X+), 4=front(Z-), 5=back(Z+)
    private static let faceDefinitions: [(corners: [Int], axis: Int)] = [
        ([0, 1, 3, 2], 1), // bottom - Y axis (green)
        ([4, 6, 7, 5], 1), // top - Y axis (green)
        ([0, 2, 6, 4], 0), // left - X axis (red)
        ([1, 5, 7, 3], 0), // right - X axis (red)
        ([0, 4, 5, 1], 2), // front - Z axis (blue)
        ([2, 3, 7, 6], 2), // back - Z axis (blue)
    ]
    
    private static let axisColors: [Color] = [.red, .green, .blue]
    private static let axisVectors: [SIMD3<Float>] = [
        SIMD3(1, 0, 0), // X
        SIMD3(0, 1, 0), // Y
        SIMD3(0, 0, 1), // Z
    ]
    
    private func computeFaces(box: BoundingBoxInfo) -> [FaceInfo] {
        let corners = box.bounds.corners
        let mv = viewMatrix * box.modelMatrix
        let mvp = projectionMatrix * mv
        
        // Transform corners to view space
        let viewCorners: [SIMD3<Float>] = corners.map { corner in
            let p = mv * SIMD4<Float>(corner, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }
        
        // Project corners to screen
        let screenPoints: [CGPoint?] = corners.map { corner in
            projectToScreen(point: corner, mvp: mvp, viewportSize: viewportSize)
        }
        
        // Compute axis directions in screen space (for drag)
        let center = box.bounds.center
        let axisScreenDirs: [CGVector] = Self.axisVectors.map { axisVec in
            let p0 = projectToScreen(point: center, mvp: mvp, viewportSize: viewportSize) ?? .zero
            let p1 = projectToScreen(point: center + axisVec * 0.1, mvp: mvp, viewportSize: viewportSize) ?? .zero
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            let len = sqrt(dx*dx + dy*dy)
            if len > 0.001 {
                return CGVector(dx: dx/len, dy: dy/len)
            }
            return CGVector(dx: 1, dy: 0)
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
            
            let center = (v0 + v1 + v2 + v3) / 4
            let toCamera = -center
            
            let isFrontFacing = dot(normal, toCamera) > 0
            
            if isFrontFacing {
                let faceScreenPoints = def.corners.compactMap { screenPoints[$0] }
                if faceScreenPoints.count == 4 {
                    faces.append(FaceInfo(
                        id: "\(box.id)-\(faceIdx)",
                        cloudID: box.id,
                        points: faceScreenPoints,
                        color: Self.axisColors[def.axis],
                        depth: center.z,
                        axis: def.axis,
                        axisDirectionScreen: axisScreenDirs[def.axis]
                    ))
                }
            }
        }
        
        return faces
    }
    
    private func computeBoxData(box: BoundingBoxInfo) -> (screenPoints: [CGPoint?], frontFacing: [Bool]) {
        let corners = box.bounds.corners
        let mv = viewMatrix * box.modelMatrix
        let mvp = projectionMatrix * mv
        
        let viewCorners: [SIMD3<Float>] = corners.map { corner in
            let p = mv * SIMD4<Float>(corner, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }
        
        let screenPoints: [CGPoint?] = corners.map { corner in
            projectToScreen(point: corner, mvp: mvp, viewportSize: viewportSize)
        }
        
        var frontFacing = [Bool](repeating: false, count: 6)
        
        for (faceIdx, def) in Self.faceDefinitions.enumerated() {
            let v0 = viewCorners[def.corners[0]]
            let v1 = viewCorners[def.corners[1]]
            let v2 = viewCorners[def.corners[2]]
            let v3 = viewCorners[def.corners[3]]
            
            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let normal = cross(edge1, edge2)
            
            let center = (v0 + v1 + v2 + v3) / 4
            let toCamera = -center
            
            frontFacing[faceIdx] = dot(normal, toCamera) > 0
        }
        
        return (screenPoints, frontFacing)
    }

    // MARK: - Wireframe Drawing
    
    private func drawWireframe(context: GraphicsContext, box: BoundingBoxInfo) {
        let data = computeBoxData(box: box)
        
        let edges: [(Int, Int, Int, Int)] = [
            (0, 1, 0, 4), (1, 3, 0, 3), (3, 2, 0, 5), (2, 0, 0, 2),
            (4, 5, 1, 4), (5, 7, 1, 3), (7, 6, 1, 5), (6, 4, 1, 2),
            (0, 4, 2, 4), (1, 5, 3, 4), (2, 6, 2, 5), (3, 7, 3, 5),
        ]
        
        for (v1, v2, f1, f2) in edges {
            guard let p1 = data.screenPoints[v1], let p2 = data.screenPoints[v2] else { continue }
            
            let isVisible = data.frontFacing[f1] || data.frontFacing[f2]
            let opacity = isVisible ? 1.0 : 0.2
            
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            
            context.stroke(path, with: .color(box.color.opacity(opacity)), lineWidth: 2)
        }
    }

    private func projectToScreen(point: SIMD3<Float>, mvp: simd_float4x4, viewportSize: CGSize) -> CGPoint? {
        let p = SIMD4<Float>(point, 1)
        let clip = mvp * p

        guard clip.w > 0 else { return nil }

        let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w

        let x = (ndc.x + 1) * 0.5 * Float(viewportSize.width)
        let y = (1 - ndc.y) * 0.5 * Float(viewportSize.height)

        guard x.isFinite && y.isFinite else { return nil }
        guard x > -1000 && x < Float(viewportSize.width) + 1000 else { return nil }
        guard y > -1000 && y < Float(viewportSize.height) + 1000 else { return nil }

        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

// MARK: - Draggable Face

struct DraggableFace: View {
    let points: [CGPoint]
    let color: Color
    let axisDirectionScreen: CGVector
    var onDrag: ((CGSize) -> Void)?
    
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var lastTranslation: CGSize = .zero
    
    private var boundingRect: CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
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
                        // Compute delta from last position
                        let delta = CGSize(
                            width: value.translation.width - lastTranslation.width,
                            height: value.translation.height - lastTranslation.height
                        )
                        lastTranslation = value.translation
                        
                        // Project drag onto axis direction
                        let dragVec = CGVector(dx: delta.width, dy: delta.height)
                        let dot = dragVec.dx * axisDirectionScreen.dx + dragVec.dy * axisDirectionScreen.dy
                        let projected = CGSize(width: dot * axisDirectionScreen.dx, height: dot * axisDirectionScreen.dy)
                        onDrag?(projected)
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastTranslation = .zero
                    }
            )
    }
}

// MARK: - Quad Shape

struct QuadShape: Shape {
    let points: [CGPoint]
    
    func path(in rect: CGRect) -> Path {
        guard points.count == 4 else { return Path() }
        
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

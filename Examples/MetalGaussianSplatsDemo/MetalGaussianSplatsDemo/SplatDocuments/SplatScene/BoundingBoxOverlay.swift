#if os(iOS) || os(macOS)
import simd
import SwiftUI

/// Overlay view that draws bounding boxes for splat clouds
struct BoundingBoxOverlay: View {
    let boundingBoxes: [BoundingBoxInfo]
    let viewMatrix: simd_float4x4
    let projectionMatrix: simd_float4x4
    let viewportSize: CGSize

    struct BoundingBoxInfo: Identifiable {
        let id: UUID
        let bounds: BoundingBox
        let modelMatrix: simd_float4x4
        let color: Color
    }

    var body: some View {
        Canvas { context, size in
            for box in boundingBoxes {
                drawBoundingBox(context: context, size: size, box: box)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawBoundingBox(context: GraphicsContext, size: CGSize, box: BoundingBoxInfo) {
        // Corners from BoundingBox:
        // 0: (min.x, min.y, min.z) - left-bottom-front
        // 1: (max.x, min.y, min.z) - right-bottom-front
        // 2: (min.x, min.y, max.z) - left-bottom-back
        // 3: (max.x, min.y, max.z) - right-bottom-back
        // 4: (min.x, max.y, min.z) - left-top-front
        // 5: (max.x, max.y, min.z) - right-top-front
        // 6: (min.x, max.y, max.z) - left-top-back
        // 7: (max.x, max.y, max.z) - right-top-back

        let corners = box.bounds.corners
        let mv = viewMatrix * box.modelMatrix
        let mvp = projectionMatrix * mv

        // Transform corners to view space
        let viewCorners: [SIMD3<Float>] = corners.map { corner in
            let p = mv * SIMD4<Float>(corner, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }

        // Project all 8 corners to screen space
        let screenPoints: [CGPoint?] = corners.map { corner in
            projectToScreen(point: corner, mvp: mvp, viewportSize: size)
        }

        // 6 faces defined by 4 corner indices each, with outward normal direction
        // Face index: 0=bottom, 1=top, 2=left, 3=right, 4=front, 5=back
        let faceCorners: [[Int]] = [
            [0, 1, 3, 2], // bottom (Y-)
            [4, 6, 7, 5], // top (Y+)
            [0, 2, 6, 4], // left (X-)
            [1, 5, 7, 3], // right (X+)
            [0, 4, 5, 1], // front (Z-)
            [2, 3, 7, 6], // back (Z+)
        ]

        // Check which faces are front-facing using cross product of edges
        var frontFacing = [Bool](repeating: false, count: 6)
        for (faceIdx, corners) in faceCorners.enumerated() {
            let v0 = viewCorners[corners[0]]
            let v1 = viewCorners[corners[1]]
            let v2 = viewCorners[corners[2]]
            
            // Two edges of the face
            let edge1 = v1 - v0
            let edge2 = v2 - v0
            
            // Normal via cross product (order gives outward normal for CCW winding)
            let normal = cross(edge1, edge2)
            
            // Face center in view space
            let center = (v0 + v1 + viewCorners[corners[2]] + viewCorners[corners[3]]) / 4
            
            // Direction from face to camera (camera at origin in view space)
            let toCamera = -center
            
            // Front-facing if normal points toward camera
            frontFacing[faceIdx] = dot(normal, toCamera) > 0
        }

        // 12 edges: (vertex1, vertex2, face1, face2)
        let edges: [(Int, Int, Int, Int)] = [
            (0, 1, 0, 4), // bottom-front
            (1, 3, 0, 3), // bottom-right
            (3, 2, 0, 5), // bottom-back
            (2, 0, 0, 2), // bottom-left
            (4, 5, 1, 4), // top-front
            (5, 7, 1, 3), // top-right
            (7, 6, 1, 5), // top-back
            (6, 4, 1, 2), // top-left
            (0, 4, 2, 4), // left-front vertical
            (1, 5, 3, 4), // right-front vertical
            (2, 6, 2, 5), // left-back vertical
            (3, 7, 3, 5), // right-back vertical
        ]

        // Draw edges
        for (v1, v2, f1, f2) in edges {
            guard let p1 = screenPoints[v1], let p2 = screenPoints[v2] else { continue }
            
            // Edge is visible if at least one adjacent face is front-facing
            let isVisible = frontFacing[f1] || frontFacing[f2]
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

        // Behind camera
        guard clip.w > 0 else { return nil }

        // Perspective divide
        let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w

        // NDC to screen (flip Y for SwiftUI coordinates)
        let x = (ndc.x + 1) * 0.5 * Float(viewportSize.width)
        let y = (1 - ndc.y) * 0.5 * Float(viewportSize.height)

        // Clip to reasonable bounds
        guard x.isFinite && y.isFinite else { return nil }
        guard x > -1000 && x < Float(viewportSize.width) + 1000 else { return nil }
        guard y > -1000 && y < Float(viewportSize.height) + 1000 else { return nil }

        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}
#endif

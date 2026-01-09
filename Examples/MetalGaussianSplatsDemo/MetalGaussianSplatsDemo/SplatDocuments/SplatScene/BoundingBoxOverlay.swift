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
        let corners = box.bounds.corners
        let mvp = projectionMatrix * viewMatrix * box.modelMatrix

        // Project all 8 corners to screen space
        let screenPoints = corners.map { corner -> CGPoint? in
            projectToScreen(point: corner, mvp: mvp, viewportSize: size)
        }

        // Define the 12 edges of a box (pairs of corner indices)
        let edges: [(Int, Int)] = [
            // Bottom face
            (0, 1), (1, 3), (3, 2), (2, 0),
            // Top face
            (4, 5), (5, 7), (7, 6), (6, 4),
            // Vertical edges
            (0, 4), (1, 5), (2, 6), (3, 7)
        ]

        // Draw edges
        for (i, j) in edges {
            guard let p1 = screenPoints[i], let p2 = screenPoints[j] else { continue }
            
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            
            context.stroke(path, with: .color(box.color), lineWidth: 2)
        }

        // Draw corner points
        for point in screenPoints {
            guard let p = point else { continue }
            let rect = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: rect), with: .color(box.color))
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

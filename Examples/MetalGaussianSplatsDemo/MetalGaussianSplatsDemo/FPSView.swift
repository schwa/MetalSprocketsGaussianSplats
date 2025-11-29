#if os(iOS) || (os(macOS) && !arch(x86_64))
import SwiftUI

struct FPSView: View {
    var fps: Double

    private var fpsColor: Color {
        switch fps {
        case 55...:
            return .green
        case 45..<55:
            return .yellow
        case 30..<45:
            return .orange
        default:
            return .red
        }
    }

    var body: some View {
        Text(String(format: "%.1f FPS", fps))
            .font(.system(.body, design: .monospaced, weight: .semibold))
            .foregroundStyle(fpsColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

#endif

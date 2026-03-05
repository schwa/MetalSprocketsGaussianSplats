import SwiftUI

/// A view that displays the source image while conversion to 3DGS is in progress.
struct ImageConversionView: View {
    let sourceImage: PlatformImage
    let statusMessage: String

    var body: some View {
        ZStack {
            // Source image as blurred background
            platformImage(sourceImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 20)
                .overlay(Color.black.opacity(0.5))

            VStack(spacing: 24) {
                // Original image preview
                platformImage(sourceImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 400, maxHeight: 300)
                    .glimmer(
                        sweepDuration: 1.0,
                        pauseDuration: 1.5,
                        gradientWidth: 0.4,
                        maxLightness: 0.3,
                        angle: 90.0,
                        rainbowSpeed: 0.3
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 20)

                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)

                    Text(statusMessage)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Converting image: \(statusMessage)")
    }

    private func platformImage(_ image: PlatformImage) -> Image {
        #if os(macOS)
        // swiftlint:disable:next accessibility_label_for_image
        Image(nsImage: image)
        #else
        // swiftlint:disable:next accessibility_label_for_image
        Image(uiImage: image)
        #endif
    }
}

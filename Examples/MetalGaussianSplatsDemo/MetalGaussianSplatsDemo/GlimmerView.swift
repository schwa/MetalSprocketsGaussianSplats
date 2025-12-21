//
// GlimmerView.swift
// MetalGaussianSplatsDemo
//
// An animated glimmer effect using SwiftUI Metal shaders.
// Inspired by Inferno by Paul Hudson (https://github.com/twostraws/Inferno)
//

import SwiftUI

/// A view modifier that applies an animated glimmer effect to its content.
struct GlimmerModifier: ViewModifier {
    /// The duration of the glimmer sweep across the view in seconds.
    var sweepDuration: Double = 1.5

    /// The pause duration before the next sweep starts in seconds.
    var pauseDuration: Double = 3.0

    /// The width of the glimmer gradient as a fraction of the view width (0-1).
    var gradientWidth: Double = 0.3

    /// The maximum lightness boost at the peak of the glimmer (0-1).
    var maxLightness: Double = 0.5

    /// The angle of the glimmer sweep in degrees (0 = horizontal, 45 = diagonal).
    var angle: Double = 45.0

    /// The start time for the animation.
    private let startDate = Date()

    func body(content: Content) -> some View {
        TimelineView(.animation) { timeline in
            let elapsedTime = timeline.date.timeIntervalSince(startDate)

            content
                .modifier(GlimmerShaderModifier(
                    elapsedTime: elapsedTime,
                    sweepDuration: sweepDuration,
                    pauseDuration: pauseDuration,
                    gradientWidth: gradientWidth,
                    maxLightness: maxLightness,
                    angle: angle
                ))
        }
    }
}

/// Internal modifier that applies the shader with geometry information.
private struct GlimmerShaderModifier: ViewModifier {
    let elapsedTime: Double
    let sweepDuration: Double
    let pauseDuration: Double
    let gradientWidth: Double
    let maxLightness: Double
    let angle: Double

    func body(content: Content) -> some View {
        content
            .visualEffect { content, geometryProxy in
                content
                    .colorEffect(
                        ShaderLibrary.glimmer(
                            .float2(geometryProxy.size),
                            .float(elapsedTime),
                            .float(sweepDuration),
                            .float(pauseDuration),
                            .float(gradientWidth),
                            .float(maxLightness),
                            .float(angle * .pi / 180.0)
                        )
                    )
            }
    }
}

/// A view that wraps content with an animated glimmer effect.
struct GlimmerView<Content: View>: View {
    /// The content to apply the glimmer effect to.
    @ViewBuilder var content: () -> Content

    /// The duration of the glimmer sweep across the view in seconds.
    var sweepDuration: Double = 1.5

    /// The pause duration before the next sweep starts in seconds.
    var pauseDuration: Double = 3.0

    /// The width of the glimmer gradient as a fraction of the view width (0-1).
    var gradientWidth: Double = 0.3

    /// The maximum lightness boost at the peak of the glimmer (0-1).
    var maxLightness: Double = 0.5

    /// The angle of the glimmer sweep in degrees (0 = horizontal, 45 = diagonal).
    var angle: Double = 45.0

    var body: some View {
        content()
            .glimmer(
                sweepDuration: sweepDuration,
                pauseDuration: pauseDuration,
                gradientWidth: gradientWidth,
                maxLightness: maxLightness,
                angle: angle
            )
    }
}

extension View {
    /// Applies an animated glimmer effect to the view.
    /// - Parameters:
    ///   - sweepDuration: The duration of the glimmer sweep in seconds. Default is 1.5.
    ///   - pauseDuration: The pause before the next sweep in seconds. Default is 3.0.
    ///   - gradientWidth: The width of the glimmer as a fraction of view width (0-1). Default is 0.3.
    ///   - maxLightness: The maximum lightness boost (0-1). Default is 0.5.
    ///   - angle: The angle of the glimmer sweep in degrees. Default is 45.
    /// - Returns: A view with the glimmer effect applied.
    func glimmer(
        sweepDuration: Double = 1.5,
        pauseDuration: Double = 3.0,
        gradientWidth: Double = 0.3,
        maxLightness: Double = 0.5,
        angle: Double = 45.0
    ) -> some View {
        modifier(GlimmerModifier(
            sweepDuration: sweepDuration,
            pauseDuration: pauseDuration,
            gradientWidth: gradientWidth,
            maxLightness: maxLightness,
            angle: angle
        ))
    }
}

#Preview("Glimmer Effect") {
    VStack(spacing: 40) {
        Image(systemName: "sparkles")
            .font(.system(size: 80))
            .foregroundStyle(.blue)
            .glimmer()

        GlimmerView {
            RoundedRectangle(cornerRadius: 20)
                .fill(.linearGradient(
                    colors: [.purple, .blue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 200, height: 100)
        }

        Text("Glimmer Effect")
            .font(.largeTitle)
            .fontWeight(.bold)
            .foregroundStyle(.orange)
            .glimmer(sweepDuration: 1.0, pauseDuration: 2.0, maxLightness: 0.7)
    }
    .padding(50)
}

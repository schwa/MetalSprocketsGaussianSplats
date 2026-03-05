#include <metal_stdlib>
using namespace metal;

/// Converts a color from RGB to HSL representation.
half3 rgbToHSL(half3 rgb) {
    half minVal = min3(rgb.r, rgb.g, rgb.b);
    half maxVal = max3(rgb.r, rgb.g, rgb.b);
    half delta = maxVal - minVal;

    half3 hsl = half3(0.0h, 0.0h, 0.5h * (maxVal + minVal));
    
    if (delta > 0.0h) {
        if (maxVal == rgb.r) {
            hsl[0] = fmod((rgb.g - rgb.b) / delta, 6.0h);
        } else if (maxVal == rgb.g) {
            hsl[0] = (rgb.b - rgb.r) / delta + 2.0h;
        } else {
            hsl[0] = (rgb.r - rgb.g) / delta + 4.0h;
        }
        hsl[0] /= 6.0h;
        if (hsl[2] > 0.0h && hsl[2] < 1.0h) {
            hsl[1] = delta / (1.0h - abs(2.0h * hsl[2] - 1.0h));
        } else {
            hsl[1] = 0.0h;
        }
    }
    
    return hsl;
}

/// Converts a color from HSL to RGB representation.
half3 hslToRGB(half3 hsl) {
    half c = (1.0h - abs(2.0h * hsl[2] - 1.0h)) * hsl[1];
    half h = hsl[0] * 6.0h;
    half x = c * (1.0h - abs(fmod(h, 2.0h) - 1.0h));
    
    half3 rgb = half3(0.0h, 0.0h, 0.0h);
    
    if (h < 1.0h) {
        rgb = half3(c, x, 0.0h);
    } else if (h < 2.0h) {
        rgb = half3(x, c, 0.0h);
    } else if (h < 3.0h) {
        rgb = half3(0.0h, c, x);
    } else if (h < 4.0h) {
        rgb = half3(0.0h, x, c);
    } else if (h < 5.0h) {
        rgb = half3(x, 0.0h, c);
    } else {
        rgb = half3(c, 0.0h, x);
    }
    
    half m = hsl[2] - 0.5h * c;
    return rgb + m;
}

/// A shader that generates a glimmer/shimmer effect sweeping across the content.
///
/// - Parameter position: The user-space coordinate of the current pixel.
/// - Parameter color: The current color of the pixel.
/// - Parameter size: The size of the entire view, in user-space.
/// - Parameter time: The number of elapsed seconds since the shader was created.
/// - Parameter sweepDuration: The duration of the glimmer sweep across the view, in seconds.
/// - Parameter pauseDuration: The pause duration before the next sweep starts, in seconds.
/// - Parameter gradientWidth: The width of the glimmer gradient in UV space (0-1).
/// - Parameter maxLightness: The maximum lightness boost at the peak of the gradient (0-1).
/// - Parameter angle: The angle of the glimmer sweep in radians.
/// - Parameter tintColor: Optional tint color for the glimmer (use alpha to control blend amount).
/// - Parameter rainbowSpeed: If > 0, cycles the tint through rainbow colors at this speed (cycles per second).
/// - Returns: The new pixel color.
[[ stitchable ]] half4 glimmer(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float sweepDuration,
    float pauseDuration,
    float gradientWidth,
    float maxLightness,
    float angle,
    half4 tintColor,
    float rainbowSpeed
) {
    if (color.a == 0.0h) {
        return color;
    }

    // Total cycle = sweep + pause
    float totalCycle = sweepDuration + pauseDuration;
    float timeInCycle = fmod(time, totalCycle);

    // If we're in the pause phase, just return the original color
    if (timeInCycle >= sweepDuration) {
        return color;
    }

    // Calculate progress within the sweep phase (0 to 1)
    half progress = timeInCycle / sweepDuration;
    
    // Convert coordinate to UV space, 0 to 1.
    half2 uv = half2(position / size);
    
    // Rotate UV coordinates based on angle for diagonal sweep
    float cosAngle = cos(angle);
    float sinAngle = sin(angle);
    half rotatedU = uv.x * cosAngle + uv.y * sinAngle;

    // Calculate u beyond the views's edges based on the gradient size
    half minU = 0.0h - gradientWidth;
    half maxU = 1.0h + gradientWidth;
    
    // Based on the current progress, calculate the starting and ending position of the gradient
    half start = minU + (maxU - minU) * progress;
    half end = start + gradientWidth;
    
    if (rotatedU > start && rotatedU < end) {
        // Determine the pixel's position within the gradient, from 0 to 1
        half gradient = smoothstep(start, end, rotatedU);
        // Determine gradient intensity using a sine wave for smooth falloff
        half intensity = sin(gradient * M_PI_H);
        
        // Add a subtle sparkle effect
        half sparkle = sin(position.x * 0.5h + position.y * 0.3h + time * 10.0h) * 0.5h + 0.5h;
        intensity = intensity * (0.8h + 0.2h * sparkle);

        // Convert from RGB to HSL
        half3 hsl = rgbToHSL(color.rgb);
        // Modify the lightness component based on intensity
        hsl[2] = hsl[2] + half(maxLightness * (1.0h - hsl[2])) * intensity;
        // Convert back to RGB
        half3 resultRGB = hslToRGB(hsl);

        // Blend in tint color if alpha > 0, or use rainbow if rainbowSpeed > 0
        if (rainbowSpeed > 0.0h) {
            // Cycle hue based on time
            half hue = half(fmod(float(time * rainbowSpeed), 1.0f));
            half3 rainbowRGB = hslToRGB(half3(hue, 1.0h, 0.6h));
            half tintAmount = tintColor.a * intensity;
            resultRGB = mix(resultRGB, rainbowRGB, tintAmount);
        } else if (tintColor.a > 0.0h) {
            half tintAmount = tintColor.a * intensity;
            resultRGB = mix(resultRGB, tintColor.rgb, tintAmount);
        }

        color.rgb = resultRGB;
    }
    
    return color;
}

#if !arch(x86_64)

import Metal
#if canImport(MetalFX)
import MetalFX
#endif
import MetalSprockets
import MetalSprocketsSupport

/// Shared helpers for MetalFX spatial upscaling of splat renders.
enum MetalFXUpscale {
    static func isSupported(device: MTLDevice) -> Bool {
        #if canImport(MetalFX)
        MTLFXSpatialScalerDescriptor.supportsMetal4FX(device)
        #else
        false
        #endif
    }

    /// Makes the private, full-size texture MetalFX writes into.
    static func makeOutputTexture(device: MTLDevice, pixelFormat: MTLPixelFormat, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let texture = try device.makeTexture(descriptor: descriptor).orThrow(.resourceCreationFailure("Failed to create MetalFX output texture"))
        texture.label = "MetalFX upscaled"
        return texture
    }

    static func element(input: MTLTexture, output: MTLTexture) -> AnyElement {
        #if canImport(MetalFX)
        MetalFXSpatial(inputTexture: input, outputTexture: output).eraseToAnyElement()
        #else
        EmptyElement().eraseToAnyElement()
        #endif
    }

    /// Copies a private texture into a shared one so the CPU can read it.
    static func readableCopy(of texture: MTLTexture, using renderer: OffscreenRenderer) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        let copy = try texture.device.makeTexture(descriptor: descriptor).orThrow(.resourceCreationFailure("Failed to create readback texture"))
        _ = try renderer.render(
            ComputePass {
                ComputeCommand { encoder in
                    encoder.copy(sourceTexture: texture, destinationTexture: copy)
                }
                .useComputeResources([texture, copy], usage: [.read, .write])
            }
        )
        return copy
    }
}

#endif

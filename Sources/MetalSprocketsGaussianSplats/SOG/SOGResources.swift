#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import Metal
import MetalSprocketsSupport

/// Container for SOG textures and codebook buffers for GPU rendering
public struct SOGResources: @unchecked Sendable {
    public let metadata: SOGMetadata
    public let count: Int

    // Positions buffer (decoded from textures)
    public let positions: TypedMTLBuffer<SIMD3<Float>>

    // Bounds from metadata
    public let mins: SIMD3<Float>
    public let maxs: SIMD3<Float>

    // Textures
    public let meansLowTexture: MTLTexture
    public let meansHighTexture: MTLTexture
    public let scalesTexture: MTLTexture
    public let quatsTexture: MTLTexture
    public let sh0Texture: MTLTexture

    // Codebook buffers
    public let scalesCodebook: TypedMTLBuffer<Float>
    public let sh0Codebook: TypedMTLBuffer<Float>

    // Texture dimensions (for coordinate calculation)
    public let textureWidth: Int

    public init(
        metadata: SOGMetadata,
        positions: TypedMTLBuffer<SIMD3<Float>>,
        mins: SIMD3<Float>,
        maxs: SIMD3<Float>,
        meansLowTexture: MTLTexture,
        meansHighTexture: MTLTexture,
        scalesTexture: MTLTexture,
        quatsTexture: MTLTexture,
        sh0Texture: MTLTexture,
        scalesCodebook: TypedMTLBuffer<Float>,
        sh0Codebook: TypedMTLBuffer<Float>
    ) {
        self.metadata = metadata
        self.count = metadata.count
        self.positions = positions
        self.mins = mins
        self.maxs = maxs
        self.meansLowTexture = meansLowTexture
        self.meansHighTexture = meansHighTexture
        self.scalesTexture = scalesTexture
        self.quatsTexture = quatsTexture
        self.sh0Texture = sh0Texture
        self.scalesCodebook = scalesCodebook
        self.sh0Codebook = sh0Codebook

        self.textureWidth = meansLowTexture.width
    }
}

#endif

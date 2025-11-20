#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

/// Compute pass element that converts SOG resources to GenericSplat buffer
/// Use this within a MetalSprockets rendering pipeline
public struct SOGToGenericSplatComputePass: Element {
    var resources: SOGResources
    var outputBuffer: TypedMTLBuffer<GenericSplat>

    @MSState
    var computeKernel: ComputeKernel

    public init(
        resources: SOGResources,
        outputBuffer: TypedMTLBuffer<GenericSplat>
    ) throws {
        self.resources = resources
        self.outputBuffer = outputBuffer

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders()).namespaced("SOGToGenericSplatConversion")
        self.computeKernel = try shaderLibrary.function(named: "sog_to_generic_splat", type: ComputeKernel.self)
    }

    public var body: some Element {
        get throws {
            try ComputePass(label: "SOG to GenericSplat Conversion") {
                try ComputePipeline(computeKernel: computeKernel) {
                    try ComputeDispatch(
                        threadsPerGrid: MTLSize(width: resources.count, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
                    )
                    // Textures
                    .parameter("scalesTex", texture: resources.scalesTexture)
                    .parameter("quatsTex", texture: resources.quatsTexture)
                    .parameter("sh0Tex", texture: resources.sh0Texture)
                    // Input buffers
                    .parameter("positions", buffer: resources.positions.unsafeMTLBuffer)
                    .parameter("scalesCodebook", buffer: resources.scalesCodebook.unsafeMTLBuffer)
                    .parameter("sh0Codebook", buffer: resources.sh0Codebook.unsafeMTLBuffer)
                    // Output buffer
                    .parameter("genericSplats", buffer: outputBuffer.unsafeMTLBuffer)
                    // Uniforms
                    .parameter("splatCount", value: UInt32(resources.count))
                    .parameter("textureWidth", value: UInt32(resources.textureWidth))
                }
            }
        }
    }
}

/// Standalone converter to transform SOG resources into GenericSplat array using GPU compute
@MainActor
public struct SOGToGenericSplatConverter {
    private let device: MTLDevice
    private let computeKernel: ComputeKernel

    public init(device: MTLDevice) throws {
        self.device = device

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders()).namespaced("SOGToGenericSplatConversion")
        self.computeKernel = try shaderLibrary.function(named: "sog_to_generic_splat", type: ComputeKernel.self)
    }

    /// Converts SOG resources to an array of GenericSplat using GPU compute
    public func convert(_ resources: SOGResources) throws -> [GenericSplat] {
        let outputBuffer = try convertToBuffer(resources)
        let pointer = outputBuffer.unsafeMTLBuffer.contents().bindMemory(
            to: GenericSplat.self,
            capacity: resources.count
        )
        return Array(UnsafeBufferPointer(start: pointer, count: resources.count))
    }

    /// Converts SOG resources to a TypedMTLBuffer of GenericSplat (stays on GPU)
    public func convertToBuffer(_ resources: SOGResources) throws -> TypedMTLBuffer<GenericSplat> {
        var outputBuffer = try device.makeTypedBuffer(
            element: GenericSplat.self,
            capacity: resources.count,
            options: .storageModeShared
        )
        outputBuffer.count = resources.count

        let computePass = try ComputePass {
            try ComputePipeline(computeKernel: computeKernel) {
                try ComputeDispatch(
                    threadsPerGrid: MTLSize(width: resources.count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
                )
                .parameter("scalesTex", texture: resources.scalesTexture)
                .parameter("quatsTex", texture: resources.quatsTexture)
                .parameter("sh0Tex", texture: resources.sh0Texture)
                .parameter("positions", buffer: resources.positions.unsafeMTLBuffer)
                .parameter("scalesCodebook", buffer: resources.scalesCodebook.unsafeMTLBuffer)
                .parameter("sh0Codebook", buffer: resources.sh0Codebook.unsafeMTLBuffer)
                .parameter("genericSplats", buffer: outputBuffer.unsafeMTLBuffer)
                .parameter("splatCount", value: UInt32(resources.count))
                .parameter("textureWidth", value: UInt32(resources.textureWidth))
            }
        }

        try computePass.run()

        return outputBuffer
    }
}

#endif

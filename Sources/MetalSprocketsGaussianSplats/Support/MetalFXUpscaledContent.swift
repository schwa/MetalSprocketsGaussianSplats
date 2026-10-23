#if !arch(x86_64)

import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

/// Render targets for MetalFX upscaling, rebuilt when the sizes change.
final class MetalFXUpscaleTargets {
    let device: MTLDevice
    private(set) var input: MTLTexture?
    private(set) var output: MTLTexture?
    let resources: ResourceCollection

    init(device: MTLDevice) throws {
        self.device = device
        resources = try ResourceCollection(device: device)
    }

    func update(inputSize: SIMD2<Int>, outputSize: SIMD2<Int>, pixelFormat: MTLPixelFormat) throws {
        if let input, let output, input.width == inputSize.x, input.height == inputSize.y, output.width == outputSize.x, output.height == outputSize.y, output.pixelFormat == pixelFormat {
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: inputSize.x, height: inputSize.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let newInput = try device.makeTexture(descriptor: descriptor).orThrow(.resourceCreationFailure("Failed to create MetalFX input texture"))
        newInput.label = "MetalFX input"
        let newOutput = try MetalFXUpscale.makeOutputTexture(device: device, pixelFormat: pixelFormat, width: outputSize.x, height: outputSize.y)
        for texture in [input, output].compactMap(\.self) {
            resources.unregister(texture)
        }
        try resources.register(newInput)
        try resources.register(newOutput)
        input = newInput
        output = newOutput
    }
}

/// Renders `content` into a reduced-size target, upscales it with MetalFX, and
/// draws the result into the current render target.
struct MetalFXUpscaledContent<Content: Element>: Element {
    var content: Content
    var targets: MetalFXUpscaleTargets
    var clearColor: MTLClearColor

    let blitVertexShader: VertexShader
    let blitFragmentShader: FragmentShader

    init(targets: MetalFXUpscaleTargets, inputSize: SIMD2<Int>, outputSize: SIMD2<Int>, pixelFormat: MTLPixelFormat, clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0), @ElementBuilder content: () throws -> Content) throws {
        try targets.update(inputSize: inputSize, outputSize: outputSize, pixelFormat: pixelFormat)
        self.content = try content()
        self.targets = targets
        self.clearColor = clearColor
        let library = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("BlitShader")
        blitVertexShader = try library.function(named: "vertex_main", type: VertexShader.self)
        var constants = FunctionConstants()
        constants["convert_srgb_to_linear"] = .bool(false)
        blitFragmentShader = try library.function(named: "fragment_main", type: FragmentShader.self, constants: constants)
    }

    var body: some Element {
        get throws {
            let input = try targets.input.orThrow(.generic("MetalFX targets not sized"))
            let output = try targets.output.orThrow(.generic("MetalFX targets not sized"))
            let descriptor = makeInputDescriptor(input: input)
            try Group {
                content
                    .renderPassDescriptor(descriptor)
                    .useResourceCollection(targets.resources)
                MetalFXUpscale.element(input: input, output: output)
                try RenderPass {
                    try RenderPipeline(vertexShader: blitVertexShader, fragmentShader: blitFragmentShader) {
                        Draw { encoder in
                            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
                        }
                        .parameter("texture", texture: output)
                    }
                    .depthCompare(function: .always, writes: false)
                }
                .useResourceCollection(targets.resources)
            }
        }
    }

    private func makeInputDescriptor(input: MTLTexture) -> MTL4RenderPassDescriptor {
        let descriptor = MTL4RenderPassDescriptor()
        descriptor.colorAttachments[0].texture = input
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        return descriptor
    }
}

#endif

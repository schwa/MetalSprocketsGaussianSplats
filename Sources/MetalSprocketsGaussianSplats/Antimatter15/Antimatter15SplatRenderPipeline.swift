#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

public struct Antimatter15SplatRenderPipeline: Element {
    public enum DebugMode: Int32, CaseIterable {
        case off = 0
        case wireframe = 1
        case filled = 2
    }

    var splatCloud: GPUSplatCloud<Antimatter15GPUSplat>

    @MSState
    var vertexShader: VertexShader
    @MSState
    var fragmentShader: FragmentShader
    @MSState
    private var sortManager: AsyncSortManager<Antimatter15GPUSplat>?
    @MSState
    private var sortedIndices: SplatIndices?
    @MSState
    private var lastSortedCloud: GPUSplatCloud<Antimatter15GPUSplat>?

    var vertexDescriptor: MTLVertexDescriptor
    var projectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var cameraMatrix: simd_float4x4
    var drawableSize: SIMD2<Float>
    var debugMode: DebugMode

    public init(splatCloud: GPUSplatCloud<Antimatter15GPUSplat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>, debugMode: DebugMode = .wireframe) throws {
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
        self.debugMode = debugMode

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("Antimatter15SplatRenderShader")

        // Initial shader setup
        var fragmentConstants = FunctionConstants()
        fragmentConstants["debug_mode"] = .int32(debugMode.rawValue)

        self.vertexShader = try shaderLibrary.function(named: "vertex_main", type: VertexShader.self)
        self.fragmentShader = try shaderLibrary.function(named: "fragment_main", type: FragmentShader.self, constants: fragmentConstants)

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        self.vertexDescriptor = vertexDescriptor
    }

    public var body: some Element {
        get throws {
            // Do initial sort if needed - this ensures we have indices on first render
            let _ = try ensureInitialSort()
            
            // Concatenate outer modelMatrix with per-cloud transform
            let combinedModelMatrix = modelMatrix * splatCloud.modelTransform

            try Group {
                if let indexedDistancesBuffer = sortedIndices?.indices {
                    try RenderPipeline(vertexShader: vertexShader, fragmentShader: fragmentShader) {
                        Draw { commandEncoder in
                            let vertices: [SIMD2<Float>] = [
                                [-1, -1], [-1, 1], [1, -1], [1, 1]
                            ]
                            if debugMode == .wireframe {
                                commandEncoder.setTriangleFillMode(.lines)
                            }
                            commandEncoder.setVertexUnsafeBytes(of: vertices, index: 0)
                            commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: splatCloud.count)
                        }
                        .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
                        .parameter("indexedDistances", buffer: indexedDistancesBuffer.unsafeMTLBuffer)
                        .parameter("modelMatrix", value: combinedModelMatrix)
                        .parameter("viewMatrix", value: cameraMatrix.inverse)
                        .parameter("projectionMatrix", value: projectionMatrix)
                        .parameter("drawableSize", value: drawableSize)
                        .parameter("scale", value: Float(2.0))
                    }
                    .vertexDescriptor(vertexDescriptor)
                    .renderPipelineDescriptorModifier { renderPipelineDescriptor in
                        renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
                        renderPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
                        renderPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
                        renderPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                        renderPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                        renderPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                        renderPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                    }
                }
            }
            .onChange(of: debugMode) {
                do {
                    // Update shaders with new constants when debugMode changes
                    let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("Antimatter15SplatRenderShader")
                    var fragmentConstants = FunctionConstants()
                    fragmentConstants["debug_mode"] = .int32(debugMode.rawValue)
                    vertexShader = try shaderLibrary.function(named: "vertex_main", type: VertexShader.self)
                    fragmentShader = try shaderLibrary.function(named: "fragment_main", type: FragmentShader.self, constants: fragmentConstants)
                } catch {
                    fatalError("Failed to update shaders: \(error)")
                }
            }
            .onChange(of: splatCloud, initial: true) { _, _ in
                // Invalidate old sorted indices so ensureInitialSort() runs for the new cloud
                sortedIndices = nil
                lastSortedCloud = nil
                
                // Set up the async sort manager for subsequent updates.
                let device = _MTLCreateSystemDefaultDevice()
                let newSortManager = try! AsyncSortManager(device: device, splatCloud: splatCloud, capacity: splatCloud.count, logger: logger)
                sortManager = newSortManager
                nonisolated(unsafe) var sortedIndicesRef = _sortedIndices
                Task { @MainActor [sortManager = newSortManager, logger] in
                    let channel = await sortManager.sortedIndicesChannel()
                    var lastSortTime: TimeInterval = 0
                    for await sort in channel {
                        if sort.parameters.time < lastSortTime {
                            logger?.error("Out of order sort")
                            continue
                        }
                        lastSortTime = sort.parameters.time
                        sortedIndicesRef.wrappedValue = sort
                    }
                }
                
                // Request immediate sort for new cloud
                requestSort()
            }
            .onChange(of: cameraMatrix) {
                requestSort()
            }
            .onChange(of: modelMatrix) {
                requestSort()
            }
        }
    }

    @discardableResult
    private func ensureInitialSort() throws -> Bool {
        // Invalidate if cloud has changed (onChange runs after body, so check here too)
        if lastSortedCloud != splatCloud {
            sortedIndices = nil
            lastSortedCloud = splatCloud
        }
        
        guard sortedIndices == nil else { return false }
        
        let device = _MTLCreateSystemDefaultDevice()
        let initialSort = try CPUSplatRadixSorter.sort(
            device: device,
            splats: splatCloud.splats,
            camera: cameraMatrix,
            model: modelMatrix * splatCloud.modelTransform,
            reversed: false
        )
        sortedIndices = initialSort
        return true
    }

    func requestSort() {
        guard let sortManager else {
            fatalError("No sort manager")
        }
        // Pass only the scene-level modelMatrix; sorter combines with cloud.modelTransform
        let parameters = SortParameters(camera: cameraMatrix, model: modelMatrix)
        sortManager.requestSort(parameters)
    }
}

#endif

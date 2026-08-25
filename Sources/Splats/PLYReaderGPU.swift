#if !arch(x86_64)
import Foundation
@preconcurrency import Metal
import MetalCompilerPluginSupport
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

public struct PLYReaderGPU {
    public struct Result {
        public var splats: TypedMTLBuffer<SparkSplat>
        public var shCoefficients: TypedMTLBuffer<Float>
        public var shDegree: UInt8
        public var count: Int
    }

    private let device: MTLDevice
    private static let runnerCache = RunnerCache()

    public init(device: MTLDevice) {
        self.device = device
    }

    public func read(url: URL, name: String? = nil) throws -> Result {
        try read(data: Data(contentsOf: url), name: name ?? url.deletingPathExtension().lastPathComponent)
    }

    public func read(data: Data, name: String? = nil) throws -> Result {
        let reader = try PLYReader(data: data)
        guard reader.format == .binaryLittleEndian, let element = reader.primaryElement else {
            throw SplatsError.unsupportedFormat("GPU PLY decoding requires a binary_little_endian vertex element")
        }
        guard !element.properties.contains(where: { $0.isList || $0.type == .double }) else {
            throw SplatsError.unsupportedFormat("GPU PLY decoding requires scalar properties no wider than 32 bits")
        }

        let count = element.count
        let recordStride = element.properties.reduce(0) { $0 + $1.type.size }
        guard count <= UInt32.max, recordStride <= UInt32.max, reader.bodyOffset + count * recordStride <= data.count else {
            throw SplatsError.invalidData
        }

        var propertyOffsets: [String: (Int32, UInt32)] = [:]
        var byteOffset = 0
        for property in element.properties {
            propertyOffsets[property.name] = (Int32(byteOffset), property.type.gpuCode)
            byteOffset += property.type.size
        }

        let shDegree: UInt8 = if propertyOffsets["f_rest_44"] != nil { 3 } else if propertyOffsets["f_rest_23"] != nil { 2 } else if propertyOffsets["f_rest_8"] != nil { 1 } else { 0 }
        let coefficientCount = [0, 3, 8, 15][Int(shDegree)]
        let names = [
            "x", "y", "z", "scale_0", "scale_1", "scale_2",
            "f_dc_0", "f_dc_1", "f_dc_2", "red", "green", "blue",
            "opacity", "alpha", "rot_0", "rot_1", "rot_2", "rot_3"
        ] + (0..<(coefficientCount * 3)).map { "f_rest_\($0)" }
        let offsets = names.map { propertyOffsets[$0]?.0 ?? -1 }
        let types = names.map { propertyOffsets[$0]?.1 ?? 0 }

        guard offsets[0] >= 0, offsets[1] >= 0, offsets[2] >= 0 else {
            throw SplatsError.invalidData
        }

        let cloudName = name ?? "splats"
        let input = try makeBuffer(data: data, label: "PLY payload (\(cloudName))")
        let offsetsBuffer = try makeBuffer(values: offsets, label: "PLY property offsets")
        let typesBuffer = try makeBuffer(values: types, label: "PLY property types")
        let splatsOut = try device.makeTypedBuffer(element: SparkSplat.self, capacity: max(count, 1), options: [.storageModeShared]).labeled("Splats (\(cloudName))")
        let shOut = try device.makeTypedBuffer(element: Float.self, capacity: max(1, count * coefficientCount * 3), options: [.storageModeShared]).labeled("SHCoefficients (\(cloudName))")
        let params = PLYDecodeParams(bodyOffset: UInt64(reader.bodyOffset), count: UInt32(count), recordStride: UInt32(recordStride), shCoefficientCount: UInt32(coefficientCount), semanticCount: UInt32(names.count))

        let kernel = try decodeKernel()
        try Self.runnerCache.run(device: device) {
            try ComputePass(label: "PLYDecode") {
                try ComputePipeline(computeKernel: kernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: max(count, 1), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                        .parameter("params", value: params)
                        .parameter("bytes", buffer: input)
                        .parameter("offsets", buffer: offsetsBuffer)
                        .parameter("types", buffer: typesBuffer)
                        .parameter("splatsOut", buffer: splatsOut.unsafeMTLBuffer)
                        .parameter("shOut", buffer: shOut.unsafeMTLBuffer)
                }
            }
        }

        var splats = splatsOut
        splats.count = count
        var sphericalHarmonics = shOut
        sphericalHarmonics.count = count * coefficientCount * 3
        return Result(splats: splats, shCoefficients: sphericalHarmonics, shDegree: shDegree, count: count)
    }

    private func decodeKernel() throws -> ComputeKernel {
        guard let bundle = Bundle.module.peerBundle(withSuffix: "MetalSprocketsGaussianSplatShaders") else {
            throw SplatsError.resourceCreationFailure("MetalSprocketsGaussianSplatShaders bundle")
        }
        return try ShaderLibrary(bundle: bundle).namespaced("PLYDecodeShader").function(named: "decode", type: ComputeKernel.self)
    }

    private func makeBuffer(data: Data, label: String) throws -> MTLBuffer {
        guard let buffer = data.withUnsafeBytes({ (bytes: UnsafeRawBufferPointer) -> MTLBuffer? in
            guard let baseAddress = bytes.baseAddress else {
                return nil
            }
            return device.makeBuffer(bytes: baseAddress, length: bytes.count, options: [.storageModeShared])
        }) else {
            throw SplatsError.resourceCreationFailure(label)
        }
        buffer.label = label
        return buffer
    }

    private func makeBuffer<T>(values: [T], label: String) throws -> MTLBuffer {
        guard let buffer = values.withUnsafeBytes({ (bytes: UnsafeRawBufferPointer) -> MTLBuffer? in
            guard let baseAddress = bytes.baseAddress else {
                return nil
            }
            return device.makeBuffer(bytes: baseAddress, length: bytes.count, options: [.storageModeShared])
        }) else {
            throw SplatsError.resourceCreationFailure(label)
        }
        buffer.label = label
        return buffer
    }
}

private extension PLYReader.PropertyType {
    var gpuCode: UInt32 {
        switch self {
        case .char: 0
        case .uchar: 1
        case .short: 2
        case .ushort: 3
        case .int: 4
        case .uint: 5
        case .float: 6
        case .double: 7
        }
    }
}
#endif

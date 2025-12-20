#if !arch(x86_64)
import CoreTransferable
import MetalSprocketsGaussianSplatShaders
import Splats

extension Array: @retroactive Transferable where Element == Antimatter15Splat {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .antimatter15Splat) { data in
            data.withUnsafeBytes { buffer in
                buffer.withMemoryRebound(to: Antimatter15Splat.self, Array.init)
            }
        }
        DataRepresentation(importedContentType: .spz) { data in
            let reader = try SPZReader(data: data)
            var splats: [Antimatter15Splat] = []
            try reader.read { _, genericSplat in
                splats.append(Antimatter15Splat(genericSplat))
            }
            return splats
        }
        DataRepresentation(importedContentType: .json) { data in
            try JSONDecoder().decode([GenericSplat].self, from: data)
                .map(Antimatter15Splat.init)
        }
        DataRepresentation(importedContentType: .ply) { data in
            let reader = try PLYSplatReader(data: data)
            var splats: [Antimatter15Splat] = []
            try reader.read { _, genericSplat in
                splats.append(Antimatter15Splat(genericSplat))
            }
            return splats
        }
    }
}
#endif // os(iOS) || (os(macOS) && !arch(x86_64))

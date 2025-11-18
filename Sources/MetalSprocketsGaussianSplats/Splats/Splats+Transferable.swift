#if os(iOS) || (os(macOS) && !arch(x86_64))
import CoreTransferable

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
            try reader.read { spzSplat in
                splats.append(Antimatter15Splat(spzSplat))
            }
            return splats
        }
        DataRepresentation(importedContentType: .json) { data in
            try JSONDecoder().decode([GenericSplat].self, from: data)
                .map(Antimatter15Splat.init)
        }
        DataRepresentation(importedContentType: .ply) { data in
            let reader = try PLYReader(data: data)
            var splats: [Antimatter15Splat] = []
            try reader.read { record in
                if let splat = Antimatter15Splat(plyRecord: record) {
                    splats.append(splat)
                }
            }
            return splats
        }
    }
}
#endif // os(iOS) || (os(macOS) && !arch(x86_64))

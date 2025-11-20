import Foundation

/// Metadata from SOG meta.json file
public struct SOGMetadata: Codable {
    public let version: Int
    public let count: Int
    public let means: MeansMetadata
    public let scales: ScalesMetadata
    public let quats: QuatsMetadata
    public let sh0: SH0Metadata
    public let shN: SHNMetadata?

    public struct MeansMetadata: Codable {
        public let mins: [Float]
        public let maxs: [Float]
        public let files: [String]
    }

    public struct ScalesMetadata: Codable {
        public let codebook: [Float]
        public let files: [String]
    }

    public struct QuatsMetadata: Codable {
        public let files: [String]
    }

    public struct SH0Metadata: Codable {
        public let codebook: [Float]
        public let files: [String]
    }

    public struct SHNMetadata: Codable {
        public let count: Int
        public let bands: Int
        public let codebook: [Float]
        public let files: [String]
    }
}

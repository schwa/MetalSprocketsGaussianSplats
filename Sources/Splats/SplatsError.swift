import Foundation

internal enum SplatsError: Error, Equatable {
    // PLY errors
    case invalidEncoding
    case invalidHeader
    case unsupportedFormat(String)
    case missingEndHeader
    case noElements
    case formatNotSet
    case invalidData

    // PLYSplat errors
    case invalidRecord(Int)

    // SOG errors
    case failedToExtractZIP
    case missingTexture(String)
    case failedToDecodeImage(String)

    // SPZ errors
    case decompressionFailed
    case invalidMagic
    case unsupportedVersion(UInt32)
    case invalidSHDegree(UInt8)
    case insufficientData
}

extension SplatsError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "PLY file has an invalid or unsupported text encoding."
        case .invalidHeader:
            "PLY header is malformed."
        case .unsupportedFormat(let format):
            "Unsupported splat format: \(format)."
        case .missingEndHeader:
            "PLY header is missing the end_header marker."
        case .noElements:
            "PLY file declares no elements."
        case .formatNotSet:
            "PLY header does not declare a format."
        case .invalidData:
            "Splat file contains invalid data."
        case .invalidRecord(let index):
            "Splat record \(index) is malformed."
        case .failedToExtractZIP:
            "SOG file is not a readable ZIP archive."
        case .missingTexture(let filename):
            "SOG archive is missing '\(filename)'."
        case .failedToDecodeImage(let filename):
            "Could not decode '\(filename)' from the SOG archive. The image may use a WebP feature this platform's decoder does not support."
        case .decompressionFailed:
            "SPZ payload failed to decompress."
        case .invalidMagic:
            "File does not start with the SPZ magic number."
        case .unsupportedVersion(let version):
            "Unsupported SPZ version \(version)."
        case .invalidSHDegree(let degree):
            "SPZ declares an invalid spherical harmonics degree (\(degree))."
        case .insufficientData:
            "SPZ file is truncated."
        }
    }
}

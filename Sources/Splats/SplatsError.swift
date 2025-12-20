import Foundation

internal enum SplatsError: Error, Equatable {
    // Antimatter15 errors
    case invalidFileSize

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

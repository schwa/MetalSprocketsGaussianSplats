# MetalSprocketsGaussianSplats Test Plan

Automated test plan for Swift Testing framework. Each section maps to a `@Suite` with individual `@Test` functions.

---

## 1. SplatsTests Target

### GenericSplatTests

```swift
@Suite struct GenericSplatTests {
    @Test func initWithAllProperties()
    @Test func initWithQuaternion()
    @Test func defaultValues()
    @Test func equality()
    @Test func decodableFromJSON()
}
```

### ExtendedSplatTests

```swift
@Suite struct ExtendedSplatTests {
    @Test func initWithSH()
    @Test func initWithoutSH()
    @Test func shArraySizeDegree1()  // 3 coefficients
    @Test func shArraySizeDegree2()  // 8 coefficients
    @Test func shArraySizeDegree3()  // 15 coefficients
}
```

### PLYReaderTests

```swift
@Suite struct PLYReaderTests {
    @Test func parseASCIIHeader()
    @Test func parseBinaryLittleEndianHeader()
    @Test func parseBinaryBigEndianHeader()
    @Test func elementCounting()
    @Test func allPropertyTypes()  // char, uchar, short, ushort, int, uint, float, double
    @Test func listProperties()
    @Test func readASCIIData()
    @Test func readBinaryData()
    @Test func rejectInvalidMagic()
    @Test func errorOnMissingEndHeader()
    @Test func errorOnTruncatedData()
}
```

### PLYSplatReaderTests

```swift
@Suite struct PLYSplatReaderTests {
    @Test func readSplatsFromFile()  // existing
    @Test func positionExtraction()
    @Test func scaleWithExp()
    @Test func colorFromFDC()
    @Test func colorFromRGBFallback()
    @Test func opacitySigmoid()
    @Test func rotationQuaternionNormalized()
    @Test func detectSHDegree0()
    @Test func detectSHDegree1()
    @Test func detectSHDegree2()
    @Test func detectSHDegree3()
    @Test func extractSHCoefficients()
}
```

### SPZReaderTests

```swift
@Suite struct SPZReaderTests {
    @Test func readSplatsFromFile()  // existing
    @Test func gzipDecompression()
    @Test func version2Parsing()
    @Test func version3Parsing()
    @Test func positionUnpacking()
    @Test func alphaInverseSigmoid()
    @Test func colorUnpacking()
    @Test func scaleFromLogSpace()
    @Test func rotationV2()
    @Test func rotationV3SmallestThree()
    @Test func sphericalHarmonicsExtraction()
    @Test func rejectInvalidMagic()
    @Test func rejectUnsupportedVersion()
    @Test func errorOnInsufficientData()
}
```

### Antimatter15ReaderTests

```swift
@Suite struct Antimatter15ReaderTests {
    @Test func readSplatsFromFile()  // existing
    @Test func positionThreeFloats()
    @Test func scaleThreeFloats()
    @Test func colorFourBytes()
    @Test func rotationWXYZOrder()
    @Test func rejectInvalidFileSize()
    @Test func handleEmptyFile()
}
```

### SOGReaderCPUTests

```swift
@Suite struct SOGReaderCPUTests {
    @Test func readSplatsFromFile()  // existing
    @Test func initFromData()  // existing
    @Test func zipExtraction()
    @Test func metadataJsonParsing()
    @Test func meansTextureDecoding()
    @Test func scalesCodebookLookup()
    @Test func quaternionSmallestThree()
    @Test func sh0ColorDecoding()
    @Test func shNPaletteLookup()
    @Test func errorOnMissingTexture()
    @Test func errorOnCorruptedImage()
}
```

### CrossFormatTests

```swift
@Suite struct CrossFormatTests {
    @Test func plyMatchesCSV()  // existing
    @Test func spzMatchesCSV()  // existing
    @Test func antimatter15MatchesCSV()  // existing
    @Test(.disabled("SOG quantization")) func sogMatchesCSV()  // existing
    @Test func allFormatsPositionConsistency()
    @Test func allFormatsScaleConsistency()
    @Test func allFormatsRotationConsistency()
}
```

---

## 2. MetalSprocketsGaussianSplatsTests Target

### TypedMTLBufferTests

```swift
@Suite struct TypedMTLBufferTests {
    @Test func createEmptyBuffer()  // existing
    @Test func createBufferWithValues()  // existing
    @Test func subscriptGetSet()  // existing
    @Test func iteration()  // existing
    @Test func equality()  // existing
    @Test func withUnsafePointer()  // existing
    @Test func label()  // existing
    @Test func capacityVsCount()
    @Test func mutableAccess()
}
```

### GenericSplatConversionTests

```swift
@Suite struct GenericSplatConversionTests {
    @Test func toAntimatter15GPUSplat()  // existing
    @Test func toSparkSplat()  // existing
    @Test func toAntimatter15Splat()
    @Test func antimatter15CovarianceMatrix()
    @Test func colorClampingAndQuantization()
    @Test func rotationNormalization()
    @Test func sparkHalfPrecision()
}
```

### GPUSplatCloudTests

```swift
@Suite struct GPUSplatCloudTests {
    @Test func creation()  // existing
    @Test func withManySplats()  // existing
    @Test func modelTransform()
    @Test func opacity()
    @Test func shCoefficientsBuffer()
    @Test func shDegree()
    @Test func countProperty()
    @Test func referenceEquality()
}
```

### CPURadixSortTests

```swift
@Suite struct CPURadixSortTests {
    @Test func sortEmpty()
    @Test func sortSingleElement()
    @Test func sortAlreadySorted()
    @Test func sortReversed()
    @Test func sortRandom()
    @Test func sortStability()
    @Test func sortLargeDataset()
}
```

### CPUSplatRadixSorterTests

```swift
@Suite struct CPUSplatRadixSorterTests {
    @Test func sortSingleCloud()
    @Test func sortMultipleClouds()
    @Test func distanceToCamera()
    @Test func reversedOrder()
    @Test func cloudIndexPopulated()
    @Test func perCloudModelTransform()
    @Test func sceneModelMatrix()
}
```

### AsyncSortManagerTests

```swift
@Suite struct AsyncSortManagerTests {
    @Test func initialization()
    @Test func requestSort()
    @Test func receiveViaChannel()
    @Test func coalesceRapidRequests()
    @Test func rejectOutOfOrder()
}
```

### SplatRenderingTests

```swift
@Suite struct SplatRenderingTests {
    @Test func antimatter15SingleSplat()  // existing, golden image
    @Test func antimatter15DebugModeOff()
    @Test func antimatter15DebugModeWireframe()
    @Test func antimatter15MultipleSplats()
    @Test func antimatter15CameraMovement()
    @Test func antimatter15ModelTransform()
    @Test func antimatter15AlphaBlending()
    @Test func antimatter15EmptyCloud()
}
```

### SparkRenderingTests

```swift
@Suite struct SparkRenderingTests {
    @Test func singleCloud()
    @Test func multipleCloud()
    @Test func stereoAmplification()
    @Test func sphericalHarmonics()
    @Test func srgbToLinear()
    @Test func boundingBoxCulling()
    @Test func perCloudOpacity()
    @Test func perCloudTransform()
    @Test func cameraUpdateResort()
    @Test func modelUpdateResort()
}
```

### GoldenImageTests

```swift
@Suite struct GoldenImageTests {
    @Test func antimatter15SingleSplat()
    @Test func antimatter15Grid()
    @Test func sparkSingleSplat()
    @Test func sparkGrid()
    @Test func sparkWithSH()
    @Test func sparkMultiCloud()
    @Test func differentCameraAngles()
}
```

### EdgeCaseTests

```swift
@Suite struct EdgeCaseTests {
    @Test func zeroSplatCloud()
    @Test func singleSplatCloud()
    @Test func degenerateSplatZeroScale()
    @Test func infinitePosition()
    @Test func nanValues()
    @Test func identityRotation()
    @Test func zeroOpacity()
    @Test func cameraAtOrigin()
    @Test func cameraInsideCloud()
}
```

### ErrorHandlingTests

```swift
@Suite struct ErrorHandlingTests {
    @Test func invalidHeader()
    @Test func invalidMagic()
    @Test func unsupportedVersion()
    @Test func insufficientData()
    @Test func decompressionFailed()
    @Test func invalidFileSize()
    @Test func invalidRecord()
    @Test func missingTexture()
    @Test func failedToExtractZIP()
    @Test func failedToDecodeImage()
}
```

---

## 3. CLI Integration Tests

```swift
@Suite struct CLITests {
    @Test func renderSplatToPNG()
    @Test func loadConfigFromJSON()
    @Test func setOutputDimensions()
    @Test func setBackgroundColor()
    @Test func setCameraPosition()
    @Test func setCameraLookat()
    @Test func setCameraRotation()
    @Test func setProjectionFOV()
    @Test func setModelPosition()
    @Test func selectRenderer()
    @Test func enableSRGBToLinear()
    @Test func overrideSHDegree()
    @Test func dumpToCSV()
    @Test func renderAllFormats()  // .splat, .ply, .spz, .sog
    @Test func errorOnMissingFile()
    @Test func errorOnInvalidFormat()
}
```

---

## 4. Performance Tests

```swift
@Suite struct PerformanceTests {
    @Test func sort1KSplats()
    @Test func sort100KSplats()
    @Test func sort1MSplats()
    @Test func readLargePLY()
    @Test func readLargeSPZ()
    @Test func readLargeSOG()
}
```

---

## Existing Tests (Already Implemented)

**SplatsTests:**
- `GenericSplatTests.testGenericSplatInit`
- `SPZReaderTests.testSPZReader`
- `PLYSplatReaderTests.testPLYSplatReader`
- `Antimatter15ReaderTests.testAntimatter15Reader`
- `SOGReaderCPUTests.testSOGReaderCPU`
- `SOGReaderCPUTests.testSOGReaderCPUFromData`
- `CrossFormatTests.testPLYMatchesCSV`
- `CrossFormatTests.testSPZMatchesCSV`
- `CrossFormatTests.testAntimatter15MatchesCSV`

**MetalSprocketsGaussianSplatsTests:**
- `TypedMTLBufferTests` (7 tests)
- `GenericSplatConversionTests` (2 tests)
- `GPUSplatCloudTests` (2 tests)
- `SplatRenderingTests.testAntimatter15Rendering`

---

## Test Fixtures Required

| File | Location | Purpose |
|------|----------|---------|
| `test-grid.ply` | `Tests/SplatsTests/Fixtures/` | 100 splats, PLY format |
| `test-grid.spz` | `Tests/SplatsTests/Fixtures/` | 100 splats, SPZ format |
| `test-grid.splat` | `Tests/SplatsTests/Fixtures/` | 100 splats, Antimatter15 format |
| `test-grid.sog` | `Tests/SplatsTests/Fixtures/` | 100 splats, SOG format |
| `test-grid.csv` | `Tests/SplatsTests/Fixtures/` | Ground truth for cross-format tests |
| `Antimatter15SingleSplat.png` | `Tests/.../Golden Images/` | Golden image |

---

## Running Tests

```bash
# All tests
swift test

# Specific suite
swift test --filter GenericSplatTests

# Specific test
swift test --filter "GenericSplatTests/initWithAllProperties"
```

---

## Notes

- All rendering tests require `#if !arch(x86_64)` guard (Apple Silicon only)
- Golden image tests use `GoldenImageComparison` from the `GoldenImage` package
- Performance tests should use Swift Testing's `@Test(.timeLimit(.minutes(1)))` or measure blocks

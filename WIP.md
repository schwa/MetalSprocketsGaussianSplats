# Multi-Cloud Splat Rendering - Work In Progress

## Goal

Implement multi-cloud splat rendering support - allowing multiple splat clouds to be rendered together, each with its own transform, using a unified sorting approach and bindless/argument buffer rendering.

## Constraints & Preferences

- Only update `SparkSplatRenderPipeline` for multi-cloud; leave `Antimatter15SplatRenderPipeline` as single-cloud
- Provide single-cloud convenience wrappers around multi-cloud implementations
- No arbitrary limit on cloud count (using uint16 for cloudIndex allows up to 65535)
- Hot-swappable clouds at runtime
- Transform lives on `GPUSplatCloud`, not managed separately by renderer
- `SortParameters` is scene-level only (used as sort request identity); per-cloud transforms applied internally by sorter

## Completed

- [x] Updated `IndexedDistance` struct to include `cloudIndex: uint16` (header file)
- [x] Renamed `index` to `splatIndex` in `IndexedDistance` (header, Metal shaders, Swift)
- [x] Added `modelTransform: simd_float4x4` property to `GPUSplatCloud` with `.identity` default
- [x] Implemented two-level model transforms (scene `modelMatrix` + per-cloud `modelTransform`)
- [x] Moved `indexedDistances` from `GPUSplatCloud` to renderer-owned state (`@MSState private var sortedIndices`)
- [x] Simplified `GPUSplatCloud` init (removed `cameraMatrix`/`modelMatrix` params, no initial sort)
- [x] Added convenience init with SH data: `init(device:splats:modelTransform:shCoefficients:shDegree:)`
- [x] Updated all callers: `PreviewViewController`, `SplatCloudDescriptor`, `SplatDocumentRenderView`, `ScreenshotSheet`, `gsplat-render`, `RenderingTests`
- [x] Fixed black screen bug: `onChange` handlers must be attached to `Group { }` wrapping conditional content, not inside the conditional branch (like SwiftUI)
- [x] Added synchronous initial sort so content renders on first frame (no race with async listener setup)
- [x] **Multi-cloud sorter**: `CPUSplatRadixSorter.sort(clouds:camera:sceneModel:reversed:)` sorts all splats across clouds, populates `cloudIndex`
- [x] **Multi-cloud AsyncSortManager**: Accepts `[GPUSplatCloud]`, uses multi-cloud sort path when count > 1
- [x] Fixed preview extension version mismatch warning (0.1.2)
- [x] Added MetalSprocketsAddOns dependency for argument buffer macros
- [x] Enabled `dependency-path-suffix` in metal-compiler-plugin.json to import Support.h from AddOns
- [x] Defined `SplatCloudData` and `MultiCloudArgumentBuffer` structs in SparkSplatRenderShader.h
- [x] Created `vertex_main_multicloud` shader that uses argument buffers
- [x] Updated `SparkSplatRenderPipeline` to accept `[GPUSplatCloud]` with single-cloud convenience wrappers
- [x] Implemented `multiCloudRenderPipeline()` with argument buffer setup and resource marking
- [x] Added local `useResources` extension for marking multiple resources

## TODO / Follow-up

- [ ] **Move `useResources` to MetalSprockets** - the extension should live in the main framework, not here
- [ ] Test multi-cloud rendering with actual multiple clouds
- [ ] Investigate `testAntimatter15Rendering` test failure (may be pre-existing golden image mismatch)

## Architecture Discussion: Where Should Sorting Live?

### Current State
The render pipeline element (`SparkSplatRenderPipeline`) owns the sort manager, requests sorts, and listens for results. This works but has issues:
- Complex state management inside what should be a simple render element
- `onChange` handlers doing heavy lifting

### Proposed Refactor (Deferred)
Sorting is a rendering concern, but it belongs at the **renderer/view layer**, not the **pipeline element layer**.

```
View/Renderer Layer (e.g., SplatDocumentRenderView)
  - owns splatCloud(s)
  - owns sortManager  
  - listens for sort results
  - requests sorts when camera change
  - passes sortedIndices DOWN to pipeline

Pipeline Element Layer (SparkSplatRenderPipeline)
  - takes: splatCloud, sortedIndices, camera matrices, etc.
  - pure function of inputs - just renders
  - no @MSState, no async, no sort management
```

**Decision**: Revisit after multi-cloud is functional.

## Key Files

- `Sources/MetalSprocketsGaussianSplats/Sorting/CPUSplatRadixSorter.swift`
- `Sources/MetalSprocketsGaussianSplats/Sorting/AsyncSortManager.swift`
- `Sources/MetalSprocketsGaussianSplats/Splats/GPUSplatCloud.swift`
- `Sources/MetalSprocketsGaussianSplats/Spark/SparkSplatRenderPipeline.swift`
- `Sources/MetalSprocketsGaussianSplatShaders/include/Antimatter15SplatRenderShader.h` (IndexedDistance struct)
- `Sources/MetalSprocketsGaussianSplatShaders/include/SparkSplatRenderShader.h` (SparkSplat, SplatCloudData, MultiCloudArgumentBuffer)
- `Sources/MetalSprocketsGaussianSplatShaders/Metal/SparkSplatRenderShader.metal` (vertex_main_multicloud)

## Build & Test

```bash
xcb build   # Build everything
xcb test    # Run tests (note: testAntimatter15Rendering may fail - investigate)
swift test  # Run package tests directly
```


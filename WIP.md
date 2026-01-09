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
- [x] Updated `AsyncSortManager` to combine `parameters.model * splatCloud.modelTransform`
- [x] Moved `indexedDistances` from `GPUSplatCloud` to renderer-owned state (`@MSState private var sortedIndices`)
- [x] Simplified `GPUSplatCloud` init (removed `cameraMatrix`/`modelMatrix` params, no initial sort)
- [x] Added convenience init with SH data: `init(device:splats:modelTransform:shCoefficients:shDegree:)`
- [x] Updated all callers: `PreviewViewController`, `SplatCloudDescriptor`, `SplatDocumentRenderView`, `ScreenshotSheet`, `gsplat-render`, `RenderingTests`
- [x] Fixed black screen bug: `onChange` handlers must be attached to `Group { }` wrapping conditional content, not inside the conditional branch (like SwiftUI)
- [x] Added synchronous initial sort so content renders on first frame (no race with async listener setup)

## Remaining Work

### Phase 1: Multi-Cloud Sorter
- [ ] Update `CPUSplatRadixSorter` to accept `[GPUSplatCloud]` instead of single cloud
- [ ] Populate `cloudIndex` during sort based on which cloud the splat came from
- [ ] Update `AsyncSortManager` to work with array of clouds
- [ ] Total splat count = sum of all cloud counts

### Phase 2: Multi-Cloud Renderer (SparkSplatRenderPipeline)
- [ ] Accept `[GPUSplatCloud]` instead of single cloud
- [ ] Use Metal argument buffers to pass array of cloud data pointers
- [ ] Shader looks up splat data using `cloudIndex` from `IndexedDistance`
- [ ] Handle per-cloud SH coefficients via argument buffers

### Phase 3: API Cleanup
- [ ] Single-cloud convenience wrappers that delegate to multi-cloud implementation
- [ ] Update demo app and tests

## Architecture Discussion: Where Should Sorting Live?

### Current State
The render pipeline element (`SparkSplatRenderPipeline`) owns the sort manager, requests sorts, and listens for results. This works but has issues:
- Race conditions between async listener setup and first sort
- Complex state management inside what should be a simple render element
- `onChange` handlers doing heavy lifting

### Proposed Refactor
Sorting is a rendering concern, but it belongs at the **renderer/view layer**, not the **pipeline element layer**.

```
View/Renderer Layer (e.g., SplatDocumentRenderView)
  - owns splatCloud(s)
  - owns sortManager  
  - listens for sort results
  - requests sorts when camera changes
  - passes sortedIndices DOWN to pipeline

Pipeline Element Layer (SparkSplatRenderPipeline)
  - takes: splatCloud, sortedIndices, camera matrices, etc.
  - pure function of inputs - just renders
  - no @MSState, no async, no sort management
```

Benefits:
- Pipeline element becomes simpler/pure
- Parent has full control over when/how sorting happens
- Easier multi-cloud: sort all clouds at parent level, pass unified buffer down
- No race conditions inside pipeline
- Easier to test (pass known indices)

**Decision**: Hold off on this refactor for now. Current implementation works. Revisit after multi-cloud is functional.

## Key Files

- `Sources/MetalSprocketsGaussianSplats/Sorting/CPUSplatRadixSorter.swift`
- `Sources/MetalSprocketsGaussianSplats/Sorting/AsyncSortManager.swift`
- `Sources/MetalSprocketsGaussianSplats/Splats/GPUSplatCloud.swift`
- `Sources/MetalSprocketsGaussianSplats/Spark/SparkSplatRenderPipeline.swift`
- `Sources/MetalSprocketsGaussianSplatShaders/include/Antimatter15SplatRenderShader.h` (IndexedDistance struct)

## Build & Test

```bash
xcb build   # Build everything
xcb test    # Run tests
```

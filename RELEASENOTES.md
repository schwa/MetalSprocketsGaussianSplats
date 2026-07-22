# Release Notes

## Unreleased

### Features

- Added GPU-sorted splat pipeline with frustum culling (`GPUSortedSplatRenderPipeline`):
  cull + stable compaction + two-pass radix sort encoded in the same GPU workload as
  rendering, drawing survivors via indirect draw. New `gpu` renderer mode in `SplatView`
  with a splat count / cull percentage stats overlay. Stereo/visionOS rendering supported.
- New PointSplat renderer: sort-free stochastic Gaussian point splatting (RFC 0003),
  with GPU work distribution, 2x2 supersampling and K points per thread, spherical
  harmonics, occlusion culling, temporal reprojection during camera motion (with
  toggle), proportional thinning under a framebuffer-derived point budget, and
  GPU-side indirect dispatch
- PointSplat: group-level hierarchical culling with optional Morton reorder of splats
  at load time (`ilOrdered:` on `GPUSplatCloud`) for tight group bounds
- Tile-based renderer exposed in `SplatView` and the demo
- visionOS: per-eye sorting for stereo rendering and a turnkey `SplatImmersiveContent`
  immersive space wrapper
- Ported GPU SOG reader from gaussiansplats-ios; added a pure-Swift VP8L fallback
  decoder for lossless WebP textures ImageIO rejects
- Added `managedSortedIndicesStream` to `AsyncSortManager` for simpler buffer-release
  handling
- CLI: `bench` subcommand producing renderer scaling curves (spark, gpu, tile,
  stochastic); README benchmark results section with scaling graph
- Added DocC documentation catalogs and doc comments across the package
- Splats: human-readable error descriptions

### API

- Demoted internal-only types from public: tile pipeline internals (`TileSplatResources`,
  binning/prefix-sum/sorting/heatmap passes), `AnyGPUSplatCloud`, `Pool`,
  `SingleValueStream`, `PointSplatWorkloadDistributor`
- Consolidated PointSplat error enums into a single `PointSplatError`
- Configuration structs replace the many-parameter `SparkSplatRenderPipeline` and
  `PointSplatRenderPipeline` initializers
- `SOGReaderGPU.load(url:)` renamed to `read(url:)` for reader consistency
- `SplatImmersiveRenderState.init` now throws instead of crashing via `try!`

### Fixes

- Concurrency hardening: `GPUSplatCloud` transform/opacity and `PointSplatStatistics`
  fields are now lock-guarded; `managedSortedIndicesStream` buffering bounded to the
  newest value so slow consumers cannot dequeue released buffers; ARKit demo frames
  delivered in order via a latest-value stream
- Fixed washed-out output in tile and PointSplat renderers
- Fixed mirrored anisotropic splats in PointSplat
- PointSplat resources are recreated when the splat cloud or drawable changes
- PointSplat accumulation is idempotent per frame; GPU sort advances its frame slot
  in init, not body
- Spark: `cloudDataBuffer` cached across body evaluations
- Stochastic renderer: noise seed freezes when the camera is stationary
- Demo: fixed Load button only working once; added drag & drop and a loading indicator
- Shader recreation on setting changes now propagates errors instead of `try!`/`fatalError`

### Performance

- Tile renderer precomputes per-splat conic data: ~3.5x faster
- PointSplat occlusion culling and temporal reprojection (RFC 0005)

### Other

- Demo project resolves Interaction3D from GitHub instead of a local package override
- All Metal resources now carry debug labels
- Stochastic, tile, and Spark pipelines bind uniforms/textures via `.parameter`
  instead of raw encoder calls
- Golden-image rendering test coverage
- Consolidated offscreen and live PointSplat code paths
- Documented macOS toolbar/NavigationStack blank-render limitation on `SplatView`
- New RFCs: 0002 (TileAlt), 0003 (PointSplat), 0004 (point budget thinning),
  0005 (PointSplat improvements beyond the paper)
- README: per-renderer sections

## 0.1.7

### Features

- Added `SplatView` to encapsulate `AsyncSortManager` complexity
- Added `SplatSorter` one-shot sorter; `gsplat-render` migrated to use it
- Buffer pooling for index/distance buffers in sort manager
- Stochastic and tile-based renderers marked as experimental

### Fixes

- Fixed buffer pool use-after-resize crash when switching splat clouds
- Fixed stray "that" text in MetalSupport.h

### Other

- Replaced local `BUFFER` macro with `MetalSprocketsShaders` import

## 0.1.6

### Changes

- Removed MetalSprocketsAddOns and earcut-swift dependencies, inlined MetalSupport.h

---

## 0.1.5

### Features

- Decoupled sort manager from render pipelines — renderers now take sorted index buffers directly
- Replaced `AsyncChannel` with `SingleValueStream`, removed AsyncAlgorithms dependency
- Added documentation for render pipelines, `AsyncSortManager`, and README usage section
- Added Metal debug labels to Spark and `GPUSplatCloud` buffers
- Made `sortedIndices` non-optional on render pipelines

### Fixes

- Fixed `AsyncSortManager` retain cycle that leaked `GPUSplatCloud`

### Other

- Removed MetalGaussianSplatsSuperDemo from Examples (moved to own repo)
- Pinned MetalSprocketsAddOns to version 0.1.4
- SwiftLint fixes

---

## 0.1.4

### Fixes

- Fixed sequential `AsyncChannel` sends in `sortNowAsync` blocking by splitting into separate Tasks
- Fixed `sortNowSync` called in render pipeline inits — moved to `onChange` handlers

---

## 0.1.3

### Features

- Multi-cloud rendering with argument buffers and per-cloud model transforms
- `SplatScene` document type with multi-cloud management
- Culling bounding box with draggable faces for Spark renderer
- Room navigation mode with fixed camera height and WASD controls
- Debug rendering modes (bounding boxes, debug colors, cloud opacity)
- Inspector tabs and column visibility handling
- Background color support for renders
- Golden image rendering tests for Spark and Antimatter15 renderers
- GitHub Actions CI workflow
- `SplatReader` dispatcher type for unified file format handling
- Simple demo app rendering butterfly-wings-closed.spz

### Fixes

- Fixed `AsyncChannel` send blocking by splitting event and indices sends into separate Tasks
- Fixed initial sort timing and listener startup
- Fixed splash screen Open button to load all file types

### Other

- Unified single and multi-cloud shaders into a single render pipeline
- Renamed types: removed "Unified" prefix, replaced "Content" suffix
- Added SwiftLint custom rule for local dependency paths
- Updated dependencies and platform deployment targets

---

## 0.1.2

### Changes

- Refactored guard statements for clarity in PLYSplatReader and SOGReaderCPU
- Added macOS-specific functionality to SettingsView
- Refactored model extraction process
- Create app support directory on launch

---

## 0.1.1

### Features

- Spherical harmonics rendering support (PLY, SPZ, SOG formats)
- visionOS support with immersive content rendering
- iOS/visionOS platform support with mobile-specific UI
- Gaussian Splats Preview Extension (QuickLook)
- Screenshot export functionality
- "Zoom to Fit" toggle for camera view
- Animated glimmer shader effect
- About view with acknowledgements
- Sample assets download functionality
- Image conversion views
- Multi-window support for iOS

### Fixes

- Fixed SOG quaternion decoding (smallest-3 encoding)
- Fixed SOG WebP decoding (un-premultiplying alpha)
- Corrected SPZ spherical harmonics unpacking
- Fixed x86_64 architecture guards

### Other

- Split `SplatDocumentView` into iOS/macOS and visionOS implementations
- Converted renderer to use SparkSplat exclusively
- Used half precision for `distanceToCamera` in `IndexedDistance`
- CSV export and SH debug logging in gsplat-render CLI

---

## 0.1.0

Initial release.

- Spark and Antimatter15 Gaussian splat renderers
- Tile-based renderer with prefix sum sorting
- Experimental stochastic renderer with temporal accumulation and blue noise
- File format support: `.splat`, `.spz`, `.ply`, `.sog`
- `gsplat-render` CLI tool
- Heat map and tile stats debug overlays
- FPS counter
- Camera management
- Sharp Image to Splat conversion

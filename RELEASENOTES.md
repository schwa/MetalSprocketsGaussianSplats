# Release Notes

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

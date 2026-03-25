## 1: Combine multi and single splat document view
status: closed
priority: medium
kind: none
created: 2026-02-09
updated: 2026-02-12
closed: 2026-02-12

1. Modified SplatDocumentView (iOS/macOS) to use new UnifiedSplatRenderView that wraps MultiCloudRenderView
2. Modified SplatDocumentView (visionOS) to use the same unified infrastructure
3. Updated SplatDocumentViewModel to directly load GPUSplatCloud<SparkSplat>
4. Removed SplatDocumentRenderView.swift and SplatRenderPass.swift (no longer needed)
5. Removed rendererType property and picker (standardized on Spark renderer)
6. Simplified SplatDocumentRendererSettingsView

Benefits:
- Single rendering code path for both single and multi-cloud documents
- Consistent behavior and visual appearance
- Reduced code duplication
- Easier to maintain single rendering pipeline

- 2026-02-12: Combined single and multi-splat document views by refactoring SplatDocumentView to use the same MultiCloudRenderView infrastructure as SplatSceneView. Changes include:

---

## 2: Fix the splash screen open button to load all file types
status: closed
priority: medium
kind: none
created: 2026-02-09
updated: 2026-02-17
closed: 2026-02-17

- 2026-02-17: Fixed by adding SplatSceneDocument types to allowedContentTypes and properly accessing security-scoped resources from fileImporter

---

## 3: Investigate testAntimatter15Rendering test failure
status: new
priority: low
kind: bug
created: 2026-02-19

Test may have pre-existing golden image mismatch. Needs investigation.

---

## 4: Investigate splat rendering lag vs bounding boxes
status: new
priority: medium
kind: bug
created: 2026-02-19

When camera moves, bounding box overlays move immediately but splats lag behind.

Root cause identified: SwiftUI's drag gesture updates cameraMatrix at ~60Hz+, but RenderView (MTKView-backed) only renders at display refresh rate. The bounding box overlay uses .onChange(of: cameraMatrix) so it sees every update. But RenderView's content closure captures cameraMatrix at render time, which may be several camera updates behind.

Example from logs:
- 276.230: Metal renders with camera at (0,0,5)
- 276.240-276.340: BoundingBox sees 10+ camera updates (moving to 4.09,-1.16,2.62)
- 276.354: Metal finally renders again, now with camera at (4.09,-1.16,2.62)

This is a ~100ms lag during fast movement.

Possible fixes:
1. Force MTKView to redraw when camera changes (setNeedsDisplay)
2. Use isPaused=false with preferredFramesPerSecond to match gesture rate
3. Handle at MetalSprockets level - RenderView should observe state changes

---

## 5: Refactor sorting out of pipeline element
status: open
priority: critical
kind: enhancement
created: 2026-02-19
updated: 2026-03-20

Architecture refactor: Move sort management from SparkSplatRenderPipeline to the view/renderer layer. Pipeline should be pure function of inputs (splatCloud, sortedIndices, camera matrices) with no @MSState, no async, no sort management.

---

## 6: Multi-splat mode FPS drops to ~10fps during camera rotation
status: new
priority: high
kind: bug
created: 2026-02-20

## Problem
In multi-splat mode (.splatscene files), FPS drops dramatically (to ~10fps or less) during camera rotation, while single-splat mode maintains 60fps.

## Key Findings

### What we know:
1. **RenderView.draw() is fast** - Each frame takes only 1-6ms total (content ~0.1ms, update ~1-4ms, setup ~0.1ms, workload ~0.3-1.5ms)
2. **MTKView draw calls are inconsistent** - FPS measured at draw() entry varies wildly: 60fps, then suddenly 13fps, 3fps, 0.8fps, back to 60fps
3. **Single-splat mode works fine** - 60fps maintained during rotation
4. **Sorting is NOT the bottleneck** - Disabling sorting (sortingEnabled=false) doesn't help
5. **Bounding boxes are NOT the issue** - Problem occurs with showBoundingBoxes=false
6. **SwiftUI updates are responsive** - UI elements update smoothly, only Metal view lags

### The mystery:
- CPU work per frame is fast (~1-6ms)
- But MTKView's draw(in:) is not being called at 60fps
- Something is throttling the display link or blocking main thread between draw calls

## Differences between single and multi mode:
1. NavigationSplitView with sidebar (multi only)
2. Cloud list with selection state
3. Multiple clouds being filtered/mapped each frame in `multiRenderView`
4. `preparedData` computation on each render
5. More complex document binding (`multiDocument`)

## Things tried:
- [x] Fire-and-forget AsyncChannel sends (avoid back-pressure blocking)
- [x] Sorting toggle to disable sorting entirely
- [x] LazyView for sidebars/inspector (defer content until appear)
- [x] Starting with sidebar hidden (.detailOnly)
- [ ] None of these fixed the issue

## Debug logging added:
- RenderView.draw timing: content/update/setup/workload/total/fps
- Enable via RENDERVIEW_LOG_FRAME=1 environment variable

## Theories to investigate:
1. NavigationSplitView causing layout thrashing during camera updates
2. Document binding updates causing excessive SwiftUI work
3. @Observable viewModel updates cascading to non-Metal views
4. Some Metal/CAMetalLayer issue with drawable management (note: `[CAMetalLayerDrawable texture] should not be called after already presenting` warning appears)

## Reproduction:
1. Open a .splatscene file with multiple clouds
2. Rotate camera with mouse drag
3. Observe FPS drop in Metal HUD or debug logging

- 2026-03-03: Confirmed: a .splatscene file with just a single cloud reproduces the same FPS drop. Rules out multi-cloud rendering as the cause. Issue is in the multi-mode infrastructure: NavigationSplitView, .onChange handlers syncing camera to document binding, or the Binding<SplatSceneDocument?> triggering SwiftUI re-evaluation.
- 2026-03-03: Root cause confirmed: reading multiDocument (the @Binding<SplatSceneDocument?>) anywhere in the view body during rendering creates a SwiftUI dependency that causes aggressive re-evaluation, starving the MTKView. multiDocument is read in multiRenderView, multiModeMainContent, inspectorContent, buildBoundingBoxInfos, cloudListSidebar, and all onChange handlers. Fix requires refactoring so the ViewModel owns all state needed for rendering (cloud enabled/opacity/transform/debugColor) and multiDocument is only read/written in discrete event handlers, never in computed view body properties.
- 2026-03-03: Deeper root cause found: The issue is NOT specific to multi-mode document binding reads. It affects single-mode too. Any inspector tab that takes @Binding from the @Observable ViewModel triggers the problem. Even $viewModel.cameraMode (which doesn't change during rotation) causes per-frame re-evaluation when passed as a Binding to a child view. This suggests that Binding created via $viewModel.property from an @Observable object causes observation of the entire object, not just that property. During camera rotation, cameraMatrix changes 60x/sec, which invalidates all views holding any Binding from the ViewModel. The SwiftUI Form layout pass in the inspector then starves the MTKView of draw calls. Affected: all inspector tabs (Camera, Render, Cloud) when they take Bindings from the ViewModel. Fix approach: decouple inspector from ViewModel bindings - use plain values with explicit write-back callbacks, or extract inspector-editable state into a separate @Observable object that doesn't include rapidly-changing properties like cameraMatrix.
- 2026-03-03: Proposed fix: Split ViewModel into two @Observable objects. 1) RenderState: rapidly-changing properties (cameraMatrix, currentFPS, sortEvents, frameCount). Only read by the render view, never bound to SwiftUI inspector views. 2) UIState: user-editable settings (cameraMode, backgroundColor, useSphericalHarmonics, showBoundingBoxes, debugMode, etc). Changed only by discrete user actions, safe to bind to SwiftUI forms. This prevents cross-contamination: cameraMatrix changing at 60fps only invalidates the render view, not the inspector. This is likely a general architectural pattern needed for any SwiftUI + Metal app that combines a render loop with SwiftUI controls.
- 2026-03-20: this is a swiftui issue - use the swiftui instrument.

---

## 7: Remove 'Unified' prefix from type names
status: closed
priority: low
kind: enhancement
created: 2026-03-03
closed: 2026-03-03

The 'Unified' prefix on types like UnifiedDocumentView, UnifiedSplatContentView, UnifiedSplatViewModel, UnifiedInspectorView, UnifiedCameraContent, UnifiedRenderContent, UnifiedCloudInfoContent, UnifiedInspectorTab was an artifact of merging single and multi splat views. Now that they're merged, the prefix is redundant and makes names unnecessarily long. Rename to clearer, shorter names.

- 2026-03-03: Also rename types with 'Content' suffix to use more descriptive names like Inspector, Editor, Detail. For example: UnifiedCameraContent -> CameraInspector, UnifiedRenderContent -> RenderInspector, UnifiedCloudInfoContent -> CloudInfoInspector, UnifiedSplatContentView -> SplatRenderView or similar.

---

## 8: Fix AsyncChannel send blocking: split event and indices sends into separate Tasks
status: open
priority: critical
kind: bug
created: 2026-03-05
updated: 2026-03-20

In AsyncSortManager.startSorting(), _sortEventChannel.send() and _sortedIndicesChannel.send() were in the same Task. If no consumer listened to the event channel, send() would suspend forever, blocking the indices send. Fixed by splitting into separate Tasks. Also moved sort listener startup from init() to onChange(initial: true) to avoid continuous re-sorting.

---

## 9: renderTargetArrayLength = 1 required on macOS due to visionOS cruft
status: new
priority: medium
kind: bug
created: 2026-03-05

SparkSplatRenderPipeline requires .renderPassDescriptorModifier { $0.renderTargetArrayLength = 1 } on macOS. This is visionOS stereo rendering cruft leaking into macOS. Should be handled internally by the pipeline or MetalSprockets so callers don't need to set it.

---

## 10: Add rendering unit tests with golden image comparisons
status: new
priority: high
kind: task
created: 2026-03-05

We need unit tests that render splats via OffscreenRenderer and compare against golden images. Should cover: Spark renderer with test-grid fixture, Spark renderer with butterfly sample, different camera angles, SH on/off. Use the GoldenImage framework for comparisons.

---

## 11: Memory leak: AsyncChannel send Tasks accumulate holding Metal buffers
status: closed
priority: high
kind: bug
labels: memory-leak, metal, async
created: 2026-03-09
closed: 2026-03-09

In AsyncSortManager.sortNowAsync(), the fire-and-forget Task sends to both channels sequentially:

```swift
Task {
    await _sortEventChannel.send(event)
    await _sortedIndicesChannel.send(result)
}
```

AsyncChannel.send() suspends until a consumer receives the value. If _sortEventChannel has no consumer (e.g. the simple demo never calls sortEventChannel()), the event send blocks forever. Because the sends are sequential, the _sortedIndicesChannel send is never reached either. The Task suspends indefinitely, holding a reference to result which contains a TypedMTLBuffer<IndexedDistance> (a Metal buffer).

Every call to sortNowAsync leaks one Metal buffer via a suspended Task. Combined with #12 (sortNowSync called every frame from init), this produces the unbounded accumulation of splats-indexed_distances buffers visible in the GPU debugger.

Affected code: Sources/MetalSprocketsGaussianSplats/Sorting/AsyncSortManager.swift — the Task in sortNowAsync() that sends to both _sortEventChannel and _sortedIndicesChannel sequentially.

- 2026-03-09: Fixed by #12. The leak was caused by sortNowSync being called every frame from init, with each call creating a suspended Task holding a Metal buffer via the blocked _sortEventChannel send. Removing sortNowSync from init eliminates the per-frame buffer accumulation.

---

## 12: sortNowSync called in SparkSplatRenderPipeline.init runs every frame
status: closed
priority: high
kind: bug
labels: performance
created: 2026-03-09
closed: 2026-03-09

SparkSplatRenderPipeline.init calls sortManager.sortNowSync() to perform an initial sort. Because the struct is recreated every frame as part of the declarative render tree (inside the RenderView closure), this blocking synchronous sort runs every frame instead of once.

The initial sort should be moved to an .onChange(initial: true) handler that only triggers on first creation or when the splat cloud changes.

Same issue likely applies to Antimatter15SplatRenderPipeline and SparkSplatDebugRenderPipeline.

- 2026-03-09: Moved sortNowSync out of init into onChange(initial: true) for all three render pipelines. sortedIndices is now optional, rendering skipped until first sort completes.

---

## 13: Stop using placeholder Metal debug labels
status: new
priority: medium
kind: none
created: 2026-03-19


---

## 14: Make the splat renderers take sorted index buffers instead of sort managers.
status: open
priority: critical
kind: none
created: 2026-03-20


---

## 15: Create docc docs for entire project.
status: new
priority: medium
kind: none
created: 2026-03-25


---

## 16: Create a SplatView that hides sort manager complexity
status: new
priority: medium
kind: none
created: 2026-03-25

Using the render pipelines directly requires the caller to manage the AsyncSortManager lifecycle, subscribe to sortedIndicesStream, request sorts on camera/model changes, and guard on nil sortedIndices before constructing the pipeline.

Create a high-level SplatView (SwiftUI) that encapsulates this pattern:
- Owns the AsyncSortManager internally
- Subscribes to sorted indices via .task
- Requests sorts on camera/model changes via .onChange
- Renders nothing until the first sort completes
- Exposes a simple API: pass in a splat cloud, camera, projection, model matrix, and drawable size

This would reduce the interactive rendering setup from ~20 lines to a single view.

---

## 17: Move the larger demo into own repo.
status: new
priority: medium
kind: none
created: 2026-03-25


---


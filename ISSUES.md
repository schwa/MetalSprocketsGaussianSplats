## 1: Combine multi and single splat document view
status: closed
priority: medium
kind: none
created: 2026-02-09T00:00:00+00:00
updated: 2026-02-12T00:00:00+00:00
closed: 2026-02-12T00:00:00+00:00

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

- 2026-04-02T20:21:37.387327+00:00: Combined single and multi-splat document views by refactoring SplatDocumentView to use the same MultiCloudRenderView infrastructure as SplatSceneView. Changes include:

---

## 2: Fix the splash screen open button to load all file types
status: closed
priority: medium
kind: none
created: 2026-02-09T00:00:00+00:00
updated: 2026-02-17T00:00:00+00:00
closed: 2026-02-17T00:00:00+00:00

- 2026-04-02T20:21:37.387553+00:00: Fixed by adding SplatSceneDocument types to allowedContentTypes and properly accessing security-scoped resources from fileImporter

---

## 3: Investigate testAntimatter15Rendering test failure
status: new
priority: low
kind: bug
created: 2026-02-19T00:00:00+00:00

Test may have pre-existing golden image mismatch. Needs investigation.

---

## 4: Investigate splat rendering lag vs bounding boxes
status: new
priority: medium
kind: bug
created: 2026-02-19T00:00:00+00:00

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
status: closed
priority: critical
kind: enhancement
created: 2026-02-19T00:00:00+00:00
updated: 2026-03-25T00:00:00+00:00
closed: 2026-03-25T00:00:00+00:00

Architecture refactor: Move sort management from SparkSplatRenderPipeline to the view/renderer layer. Pipeline should be pure function of inputs (splatCloud, sortedIndices, camera matrices) with no @MSState, no async, no sort management.

- 2026-04-02T20:21:37.388287+00:00: Completed: render pipelines now accept SplatIndices directly, no sort management or async state internally.

---

## 6: Multi-splat mode FPS drops to ~10fps during camera rotation
status: new
priority: high
kind: bug
created: 2026-02-20T00:00:00+00:00

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

- 2026-04-02T20:21:37.388525+00:00: Confirmed: a .splatscene file with just a single cloud reproduces the same FPS drop. Rules out multi-cloud rendering as the cause. Issue is in the multi-mode infrastructure: NavigationSplitView, .onChange handlers syncing camera to document binding, or the Binding<SplatSceneDocument?> triggering SwiftUI re-evaluation.
- 2026-04-02T20:21:37.388529+00:00: Root cause confirmed: reading multiDocument (the @Binding<SplatSceneDocument?>) anywhere in the view body during rendering creates a SwiftUI dependency that causes aggressive re-evaluation, starving the MTKView. multiDocument is read in multiRenderView, multiModeMainContent, inspectorContent, buildBoundingBoxInfos, cloudListSidebar, and all onChange handlers. Fix requires refactoring so the ViewModel owns all state needed for rendering (cloud enabled/opacity/transform/debugColor) and multiDocument is only read/written in discrete event handlers, never in computed view body properties.
- 2026-04-02T20:21:37.388535+00:00: Deeper root cause found: The issue is NOT specific to multi-mode document binding reads. It affects single-mode too. Any inspector tab that takes @Binding from the @Observable ViewModel triggers the problem. Even $viewModel.cameraMode (which doesn't change during rotation) causes per-frame re-evaluation when passed as a Binding to a child view. This suggests that Binding created via $viewModel.property from an @Observable object causes observation of the entire object, not just that property. During camera rotation, cameraMatrix changes 60x/sec, which invalidates all views holding any Binding from the ViewModel. The SwiftUI Form layout pass in the inspector then starves the MTKView of draw calls. Affected: all inspector tabs (Camera, Render, Cloud) when they take Bindings from the ViewModel. Fix approach: decouple inspector from ViewModel bindings - use plain values with explicit write-back callbacks, or extract inspector-editable state into a separate @Observable object that doesn't include rapidly-changing properties like cameraMatrix.
- 2026-04-02T20:21:37.388539+00:00: Proposed fix: Split ViewModel into two @Observable objects. 1) RenderState: rapidly-changing properties (cameraMatrix, currentFPS, sortEvents, frameCount). Only read by the render view, never bound to SwiftUI inspector views. 2) UIState: user-editable settings (cameraMode, backgroundColor, useSphericalHarmonics, showBoundingBoxes, debugMode, etc). Changed only by discrete user actions, safe to bind to SwiftUI forms. This prevents cross-contamination: cameraMatrix changing at 60fps only invalidates the render view, not the inspector. This is likely a general architectural pattern needed for any SwiftUI + Metal app that combines a render loop with SwiftUI controls.
- 2026-04-02T20:21:37.388539+00:00: this is a swiftui issue - use the swiftui instrument.

---

## 7: Remove 'Unified' prefix from type names
status: closed
priority: low
kind: enhancement
created: 2026-03-03T00:00:00+00:00
closed: 2026-03-03T00:00:00+00:00

The 'Unified' prefix on types like UnifiedDocumentView, UnifiedSplatContentView, UnifiedSplatViewModel, UnifiedInspectorView, UnifiedCameraContent, UnifiedRenderContent, UnifiedCloudInfoContent, UnifiedInspectorTab was an artifact of merging single and multi splat views. Now that they're merged, the prefix is redundant and makes names unnecessarily long. Rename to clearer, shorter names.

- 2026-04-02T20:21:37.388774+00:00: Also rename types with 'Content' suffix to use more descriptive names like Inspector, Editor, Detail. For example: UnifiedCameraContent -> CameraInspector, UnifiedRenderContent -> RenderInspector, UnifiedCloudInfoContent -> CloudInfoInspector, UnifiedSplatContentView -> SplatRenderView or similar.

---

## 8: Fix AsyncChannel send blocking: split event and indices sends into separate Tasks
status: closed
priority: critical
kind: bug
created: 2026-03-05T00:00:00+00:00
updated: 2026-03-25T00:00:00+00:00
closed: 2026-03-25T00:00:00+00:00

In AsyncSortManager.startSorting(), _sortEventChannel.send() and _sortedIndicesChannel.send() were in the same Task. If no consumer listened to the event channel, send() would suspend forever, blocking the indices send. Fixed by splitting into separate Tasks. Also moved sort listener startup from init() to onChange(initial: true) to avoid continuous re-sorting.

- 2026-04-02T20:21:37.389001+00:00: Resolved by replacing AsyncChannel with SingleValueStream and decoupling sort manager from render pipelines.

---

## 9: renderTargetArrayLength = 1 required on macOS due to visionOS cruft
status: new
priority: medium
kind: bug
created: 2026-03-05T00:00:00+00:00

SparkSplatRenderPipeline requires .renderPassDescriptorModifier { $0.renderTargetArrayLength = 1 } on macOS. This is visionOS stereo rendering cruft leaking into macOS. Should be handled internally by the pipeline or MetalSprockets so callers don't need to set it.

---

## 10: Add rendering unit tests with golden image comparisons
status: new
priority: high
kind: task
created: 2026-03-05T00:00:00+00:00

We need unit tests that render splats via OffscreenRenderer and compare against golden images. Should cover: Spark renderer with test-grid fixture, Spark renderer with butterfly sample, different camera angles, SH on/off. Use the GoldenImage framework for comparisons.

---

## 11: Memory leak: AsyncChannel send Tasks accumulate holding Metal buffers
status: closed
priority: high
kind: bug
labels: memory-leak, metal, async
created: 2026-03-09T00:00:00+00:00
closed: 2026-03-09T00:00:00+00:00

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

- 2026-04-02T20:21:37.389734+00:00: Fixed by #12. The leak was caused by sortNowSync being called every frame from init, with each call creating a suspended Task holding a Metal buffer via the blocked _sortEventChannel send. Removing sortNowSync from init eliminates the per-frame buffer accumulation.

---

## 12: sortNowSync called in SparkSplatRenderPipeline.init runs every frame
status: closed
priority: high
kind: bug
labels: performance
created: 2026-03-09T00:00:00+00:00
closed: 2026-03-09T00:00:00+00:00

SparkSplatRenderPipeline.init calls sortManager.sortNowSync() to perform an initial sort. Because the struct is recreated every frame as part of the declarative render tree (inside the RenderView closure), this blocking synchronous sort runs every frame instead of once.

The initial sort should be moved to an .onChange(initial: true) handler that only triggers on first creation or when the splat cloud changes.

Same issue likely applies to Antimatter15SplatRenderPipeline and SparkSplatDebugRenderPipeline.

- 2026-04-02T20:21:37.389969+00:00: Moved sortNowSync out of init into onChange(initial: true) for all three render pipelines. sortedIndices is now optional, rendering skipped until first sort completes.

---

## 13: Stop using placeholder Metal debug labels
status: new
priority: medium
kind: none
created: 2026-03-19T00:00:00+00:00


---

## 14: Make the splat renderers take sorted index buffers instead of sort managers.
status: closed
priority: critical
kind: none
created: 2026-03-20T00:00:00+00:00
updated: 2026-03-25T00:00:00+00:00
closed: 2026-03-25T00:00:00+00:00

- 2026-04-02T20:21:37.390466+00:00: Resolved by replacing AsyncChannel with SingleValueStream and decoupling sort manager from render pipelines.

---

## 15: Create docc docs for entire project.
status: new
priority: medium
kind: none
created: 2026-03-25T00:00:00+00:00


---

## 16: Create a SplatView that hides sort manager complexity
status: closed
priority: medium
kind: none
created: 2026-03-25T00:00:00+00:00
updated: 2026-03-31T20:31:19.151026+00:00
closed: 2026-03-31T20:31:19.151026+00:00

Using the render pipelines directly requires the caller to manage the AsyncSortManager lifecycle, subscribe to sortedIndicesStream, request sorts on camera/model changes, and guard on nil sortedIndices before constructing the pipeline.

Create a high-level SplatView (SwiftUI) that encapsulates this pattern:
- Owns the AsyncSortManager internally
- Subscribes to sorted indices via .task
- Requests sorts on camera/model changes via .onChange
- Renders nothing until the first sort completes
- Exposes a simple API: pass in a splat cloud, camera, projection, model matrix, and drawable size

This would reduce the interactive rendering setup from ~20 lines to a single view.

- 2026-04-02T20:21:37.391209+00:00: Implemented SplatView in Sources/MetalSprocketsGaussianSplats/Spark/SplatView.swift. Owns AsyncSortManager internally, subscribes to sorted indices via .task, requests sorts on camera/model changes via .onChange, renders nothing until first sort completes. Updated demo ContentView to use it.

---

## 17: Move the larger demo into own repo.
status: closed
priority: medium
kind: none
created: 2026-03-25T00:00:00+00:00
updated: 2026-03-30T00:00:00+00:00
closed: 2026-03-30T00:00:00+00:00

Move MetalGaussianSplatsSuperDemo into its own repo at ~/Projects/MetalGaussianSplatsDemo.

Done:
- Copied to ~/Projects/MetalGaussianSplatsDemo
- Changed local package ref to remote GitHub dependency
- Added README and .gitignore
- Initialized jj repo

Remaining:
- Create GitHub repo and push
- Remove Examples/MetalGaussianSplatsSuperDemo from this repo
- Update CI to remove build-super-demo job (or point to new repo)

---

## 18: Allow AsyncSortManager to switch splat cloud
status: closed
priority: medium
kind: feature
created: 2026-03-27T00:00:00+00:00
closed: 2026-03-27T00:00:00+00:00

Currently AsyncSortManager is initialised with a fixed set of GPUSplatClouds and cannot be retargeted. When switching between splats at runtime we have to create a new AsyncSortManager per cloud, which causes the sortedIndices to reset to nil on every switch — producing a blank frame and visible flicker.

We need a way to swap the active cloud(s) on an existing AsyncSortManager without recreating it. Something like:

    func setSplatClouds(_ clouds: [GPUSplatCloud<Splat>])

or a mutable splatClouds property. The sorter's internal MTLBuffer capacity would need to grow if the new cloud is larger than the original capacity.

- 2026-04-02T20:21:37.391960+00:00: Implemented setSplatClouds(_:) and setSplatCloud(_:) on AsyncSortManager. Added grow(capacity:) to CPUSplatRadixSorter. currentSortedIndices is preserved across cloud switches to prevent blank frames. Added 5 unit tests covering capacity growth, no-shrink, indices preservation, and correct sort count after switch.

---

## 19: Provide a lightweight one-shot sort helper for offline/offscreen rendering
status: closed
priority: medium
kind: feature
created: 2026-03-27T00:00:00+00:00
updated: 2026-03-30T00:00:00+00:00
closed: 2026-03-30T00:00:00+00:00

When rendering offscreen or in a single-frame context (e.g. snapshot, test, CLI tool), the full AsyncSortManager is overkill. It spins up a background task, manages streams, and holds actor state that is never needed for a single sort.

We should provide a simple public enum or struct SplatSorter with static sort methods that perform a synchronous, one-shot sort and return SplatIndices directly — no actor, no streams, no ongoing state.

API should look like:

    // Single cloud
    let indices = try SplatSorter.sort(device: device, splatCloud: cloud, parameters: sortParameters)

    // Multiple clouds
    let indices = try SplatSorter.sort(device: device, splatClouds: clouds, parameters: sortParameters)

CPUSplatRadixSorter already has internal static convenience methods (sort(device:splats:camera:model:reversed:) and sort(device:clouds:camera:sceneModel:reversed:)) that do the heavy lifting. SplatSorter should be a thin public wrapper over those.

- 2026-04-02T20:21:37.392342+00:00: Implemented SplatSorter as a public enum with two static sort methods wrapping CPUSplatRadixSorter. Handles empty cloud list gracefully. Added SplatSorterTests with 5 tests (all passing).

---

## 20: Adaptive sort algorithm: insertion sort for small camera deltas, radix sort fallback
status: new
priority: medium
kind: enhancement
labels: performance, sorting
created: 2026-03-30T00:00:00+00:00

## Summary

When the camera moves only slightly between frames, the sort index buffer is nearly sorted already. An insertion sort on nearly-sorted data is O(n) vs our radix sort which always does 2 full passes regardless. We should detect small camera movements and use insertion sort as the fast path, falling back to radix sort for large camera jumps.

## Approach

### Algorithm selection heuristic
Compare current vs previous camera matrix:
- Translation delta: `length(currentPos - previousPos)`
- Rotation delta: `dot(currentForward, previousForward)`
- If both below thresholds → insertion sort, otherwise → radix sort

Alternative/complementary: start insertion sort, count swaps, bail out to radix if swaps exceed a threshold (e.g. 2n–5n).

### Buffer reuse constraint
We intentionally allocate new sort index buffers each frame to avoid modifying a Metal buffer that may still be in-flight on the GPU. For insertion sort to work, we need the *previous* sorted order as a starting point. Options:
- Copy the previous frame's sorted buffer into a fresh buffer, then insertion sort in-place on the copy
- Double/triple-buffer the index buffers and track which are safe to reuse
- Use Metal events or completion handlers to know when a buffer is no longer in use

The copy-then-sort approach is simplest and still wins if the insertion sort pass is fast (memcpy of n elements + O(n) sort ≪ O(2n) radix sort with allocation).

## Complexity

| Scenario | Radix Sort | Insertion Sort |
|---|---|---|
| Nearly sorted | ~2n | ~n |
| Random | ~2n | ~n² (catastrophic) |

The heuristic/bail-out mechanism is critical to avoid the O(n²) case.

## Files likely affected
- `Sources/MetalSprocketsGaussianSplats/Sorting/CPUSplatRadixSorter.swift`
- `Sources/MetalSprocketsGaussianSplats/Sorting/AsyncSortManager.swift`
- New file for insertion sort implementation

Timsort is a better fit than raw insertion sort:
- Exploits existing sorted runs naturally — O(n) on nearly-sorted data
- O(n log n) worst case — no catastrophic O(n²) like insertion sort
- **Eliminates the need for a bail-out mechanism or fine-grained camera heuristic**

### Revised approach
- **Default to Timsort** for all frames
- **Detect camera teleport** (translation delta exceeds a large threshold) and force radix sort in that case
- This is a much simpler heuristic: binary decision (teleport vs not) rather than a gradient

### Tradeoff
- On fully random data, radix (2n) still beats Timsort (n log n ≈ 17n for 100k splats)
- But fully random only happens on teleport, which we catch explicitly
- For everything else Timsort adapts automatically — no tuning needed

Timsort is algorithmically ideal but significantly more complex to implement — hundreds of lines (merge runs, galloping, min-run calculation, merge stack) vs ~10 lines for insertion sort. We'd be writing it from scratch against UnsafeMutableBufferPointer<IndexedDistance>.

Insertion sort + bail-out to radix remains a viable simpler option. Keep Timsort as a future consideration if we find a good Swift implementation or if the bail-out heuristic proves fiddly to tune.

Issue #22 added buffer pooling with a release pattern:

```swift
for await indices in sortManager.sortedIndicesStream {
    if let old = sortedIndices {
        sortManager.release(old)
    }
    sortedIndices = indices
}
```

This gives us access to both the old and new buffers at the transition point. For the insertion sort optimization, we can:

1. Copy old sorted indices into the new buffer before sorting
2. Run insertion sort (or Timsort) on the nearly-sorted copy
3. Release the old buffer

The pool infrastructure is in place to support this.

- 2026-04-02T20:21:37.392727+00:00: ## Addendum: Timsort instead of insertion sort
- 2026-04-02T20:21:37.392729+00:00: ## Note on Timsort complexity
- 2026-04-02T20:21:37.392731+00:00: ## Buffer pooling enables copy-from-previous optimization

---

## 21: Rename gsplat-render to something less generic
status: new
priority: low
kind: enhancement
created: 2026-03-30T00:00:00+00:00

The CLI tool is currently named 'gsplat-render' which is generic and could conflict with other Gaussian splat tools. Consider renaming to something that reflects its connection to MetalSprockets, e.g.:

- msplat-render
- metalgsplat
- sprocket-render
- ms-gsplat

The name should be short, memorable, and clearly associated with MetalSprocketsGaussianSplats.

---

## 22: Index/distance buffer pooling for sort manager
status: closed
priority: medium
kind: feature
labels: performance, metal, sorting
created: 2026-03-31T15:58:34.956511+00:00
updated: 2026-03-31T19:59:41.594219+00:00
closed: 2026-03-31T19:59:41.594219+00:00

Create a thread-safe buffer pool for index and distance buffers used during sorting.

## Design Decisions

### Pool Architecture
- **Scope**: Per `AsyncSortManager` instance (not shared/global)
- **Ownership**: Owned by `AsyncSortManager`, passed to sorter as needed
- **Buffer size strategy**: Single fixed-size (matches `capacity`)

### Generic Pool Implementation
- **Type**: Generic `Pool<T: Sendable>` — not tied to Metal buffers specifically
- **Location**: `Sources/MetalSprocketsGaussianSplats/Support/Pool.swift`
- **Allocator**: Closure with `id: Int` parameter for optional debug labeling

### Preallocation
- Parameter with default of 0
- Typical use: 4 (in-flight MTKView buffers + 1 for sorting)
- Allocates on demand if pool exhausted

### Thread Safety
- Use `Mutex` (from Synchronization framework)
- Fallback to `OSAllocatedUnfairLock` if issues arise

### Buffer Lifecycle
- **Acquire**: `pool.acquire()` returns a buffer (allocates if pool empty)
- **Release**: Manual `pool.release(buffer)` — caller responsible for wiring up `commandBuffer.addCompletedHandler`
- Pool does NOT automatically track GPU completion

### Pool Exhaustion
- Allocate new buffer on demand
- Log warning via `os.Logger` to help tune preallocation count

### Resize Handling
- On `AsyncSortManager.resize()` (see #25), create new pool
- Old pool drains naturally as GPU completions fire and release buffers
- Same behavior for grow or shrink — rare event, simple solution

## API Shape

```swift
public final class Pool<T: Sendable>: @unchecked Sendable {
    public init(allocator: @escaping @Sendable (_ id: Int) -> T, preallocatedCount: Int = 0)
    public func acquire() -> T
    public func release(_ item: T)
}
```

## Integration

1. `AsyncSortManager` creates pool at init
2. Sorter calls `pool.acquire()` to get buffer for sort results
3. `SplatIndices` flows to caller via stream
4. Caller wires up `commandBuffer.addCompletedHandler { pool.release(buffer) }`
5. On `resize()`, manager creates new pool, old one drains

- 2026-04-02T20:21:37.393487+00:00: Implementation complete but blocked by MetalSprockets issue: `onCommandBufferCompleted` modifier does not fire. The pool infrastructure is in place and working, but buffer release cannot be wired up until MetalSprockets is fixed. See `releaseIndexBuffer(_:to:)` modifier in SparkSplatRenderPipeline.swift.
- 2026-04-02T20:21:37.393489+00:00: Blocked by MetalSprockets#290
- 2026-04-02T20:21:37.393492+00:00: Buffer pooling implemented and working. Buffers are released when new sorted indices arrive via `sortManager.release(old)`. See #26 for future ergonomics improvements.

---

## 23: Deprecate antimatter15 code
status: new
priority: low
kind: task
labels: cleanup, deprecation
created: 2026-03-31T15:59:44.214459+00:00

The antimatter15 splat format and rendering code should be deprecated and eventually removed.

**Tasks:**
- Mark antimatter15-related types and functions as deprecated
- Add deprecation warnings/documentation
- Identify all usages and plan migration path
- Eventually remove the code once no longer needed

---

## 24: Mark stochastic and tile-based renderers as experimental
status: closed
priority: low
kind: task
labels: documentation, api
created: 2026-03-31T15:59:58.870075+00:00
updated: 2026-03-31T16:02:23.492502+00:00
closed: 2026-03-31T16:02:23.492502+00:00

The stochastic and tile-based splat renderers should be clearly marked as experimental.

**Tasks:**
- Add @available or documentation annotations marking these as experimental
- Update any public API documentation to note experimental status
- Consider adding runtime warnings or logging when these renderers are used
- Ensure naming conventions reflect experimental status if appropriate

**Stochastic:**
- StochasticSplatRenderPipeline

**Tile-based:**
- TileBasedSplatPipeline
- TileBasedSplatPass
- TileSplatResources
- TileBinningCountPass
- TileBinningWritePass
- TileHeatMapRenderPass
- TilePrefixSumComputePass
- TileSortingComputePass
- TileSplatRenderPass

All types now have documentation comments with:
- Important: This renderer/type is **experimental** and may have significant changes or be removed in future versions.

- 2026-04-02T20:21:37.394247+00:00: Added experimental documentation comments to all stochastic and tile-based renderer types:

---

## 25: AsyncSortManager.grow -> resize
status: new
priority: medium
kind: none
created: 2026-03-31T16:10:00.092365+00:00


---

## 26: Simplify buffer release pattern for sortedIndicesStream consumers
status: new
priority: low
kind: enhancement
labels: api, ergonomics
created: 2026-03-31T19:59:36.671145+00:00

The current pattern requires manual release handling:

```swift
.task {
    for await indices in sortManager.sortedIndicesStream {
        if let old = sortedIndices {
            sortManager.release(old)
        }
        sortedIndices = indices
    }
}
```

Consider convenience APIs like:
- `managedSortedIndicesStream` that auto-releases previous
- `sortedIndicesTransitionStream` that yields (old, new) tuples
- `forEach` method that handles the loop pattern

This may be superseded by #16 (SplatView) which would hide this complexity entirely.

---

## 27: Add a simple VIsionPro example to the demo.
status: new
priority: medium
kind: none
created: 2026-03-31T20:32:59.252826+00:00


---

## 28: SplatIndices public init sets pool to nil causing silent release no-op
status: new
priority: medium
kind: none
created: 2026-03-31T21:11:46.670814+00:00

The public init(parameters:indices:) on SplatIndices sets pool to nil, meaning release() on indices created outside of AsyncSortManager is a silent no-op. This is a footgun for callers constructing SplatIndices manually (e.g. tests, SplatSorter). Consider making the pool non-optional or removing the public init in favour of the internal one.

---

## 29: Replace local BUFFER macro with MetalSprocketsShaders import
status: closed
priority: medium
kind: feature
created: 2026-04-02T19:15:41.570339+00:00
updated: 2026-04-02T19:39:10.176565+00:00
closed: 2026-04-02T19:39:10.176565+00:00

MetalSupport.h defines its own BUFFER macro and #ifdef __METAL_VERSION__ scaffolding. Replace with import from MetalSprocketsShaders, which now provides these cross-environment macros.

---

## 30: Get sample butterfly-wings-closed.spz working on visionOS headset in simple demo
status: new
priority: medium
kind: task
created: 2026-04-02T20:21:37.378610+00:00


---


# ISSUES.md

---

## 1: Combine multi and single splat document view

+++
status: closed
priority: medium
kind: none
created: 2026-02-09T00:00:00Z
updated: 2026-02-12T00:00:00Z
closed: 2026-02-12T00:00:00Z
+++

1. Modified SplatDocumentView (iOS/macOS) to use new UnifiedSplatRenderView that wraps MultiCloudRenderView
2. Modified SplatDocumentView (visionOS) to use the same unified infrastructure
3. Updated SplatDocumentViewModel to directly load GPUSplatCloud<SparkSplat>
4. Removed SplatDocumentRenderView.swift and SplatRenderPass.swift (no longer needed)
5. Removed rendererType property and picker (standardized on Spark renderer)
6. Simplified SplatDocumentRendererSettingsView

Benefits:

- `2026-02-09T00:00:00Z`: Single rendering code path for both single and multi-cloud documents
- `2026-02-09T00:00:00Z`: Consistent behavior and visual appearance
- `2026-02-09T00:00:00Z`: Reduced code duplication
- `2026-02-09T00:00:00Z`: Easier to maintain single rendering pipeline
- `2026-04-02T20:21:37Z`: Combined single and multi-splat document views by refactoring SplatDocumentView to use the same MultiCloudRenderView infrastructure as SplatSceneView. Changes include:

---

## 2: Fix the splash screen open button to load all file types

+++
status: closed
priority: medium
kind: none
created: 2026-02-09T00:00:00Z
updated: 2026-02-17T00:00:00Z
closed: 2026-02-17T00:00:00Z
+++

- `2026-04-02T20:21:37Z`: Fixed by adding SplatSceneDocument types to allowedContentTypes and properly accessing security-scoped resources from fileImporter

---

## 3: Investigate testAntimatter15Rendering test failure

+++
status: closed
priority: low
kind: bug
labels: effort:s
created: 2026-02-19T00:00:00Z
updated: 2026-04-09T22:56:28Z
closed: 2026-04-09T22:56:28Z
+++

Test may have pre-existing golden image mismatch. Needs investigation.

- `2026-04-09T16:57:35Z`: Related to #23 (deprecate antimatter15). If #23 is completed, this becomes moot.
- `2026-04-09T22:56:28Z`: Moot: Antimatter15 code removed entirely in #23.

---

## 4: Investigate splat rendering lag vs bounding boxes

+++
status: open
priority: medium
kind: bug
labels: effort:m
created: 2026-02-19T00:00:00Z
updated: 2026-04-09T16:59:20Z
+++

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

+++
status: closed
priority: critical
kind: enhancement
created: 2026-02-19T00:00:00Z
updated: 2026-03-25T00:00:00Z
closed: 2026-03-25T00:00:00Z
+++

Architecture refactor: Move sort management from SparkSplatRenderPipeline to the view/renderer layer. Pipeline should be pure function of inputs (splatCloud, sortedIndices, camera matrices) with no @MSState, no async, no sort management.

- `2026-04-02T20:21:37Z`: Completed: render pipelines now accept SplatIndices directly, no sort management or async state internally.

---

## 6: Multi-splat mode FPS drops to ~10fps during camera rotation

+++
status: open
priority: high
kind: bug
labels: effort:xl
created: 2026-02-20T00:00:00Z
updated: 2026-04-09T16:59:20Z
+++

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

- `2026-04-02T20:21:37Z`: Confirmed: a .splatscene file with just a single cloud reproduces the same FPS drop. Rules out multi-cloud rendering as the cause. Issue is in the multi-mode infrastructure: NavigationSplitView, .onChange handlers syncing camera to document binding, or the Binding<SplatSceneDocument?> triggering SwiftUI re-evaluation.
- `2026-04-02T20:21:37Z`: Root cause confirmed: reading multiDocument (the @Binding<SplatSceneDocument?>) anywhere in the view body during rendering creates a SwiftUI dependency that causes aggressive re-evaluation, starving the MTKView. multiDocument is read in multiRenderView, multiModeMainContent, inspectorContent, buildBoundingBoxInfos, cloudListSidebar, and all onChange handlers. Fix requires refactoring so the ViewModel owns all state needed for rendering (cloud enabled/opacity/transform/debugColor) and multiDocument is only read/written in discrete event handlers, never in computed view body properties.
- `2026-04-02T20:21:37Z`: Deeper root cause found: The issue is NOT specific to multi-mode document binding reads. It affects single-mode too. Any inspector tab that takes @Binding from the @Observable ViewModel triggers the problem. Even $viewModel.cameraMode (which doesn't change during rotation) causes per-frame re-evaluation when passed as a Binding to a child view. This suggests that Binding created via $viewModel.property from an @Observable object causes observation of the entire object, not just that property. During camera rotation, cameraMatrix changes 60x/sec, which invalidates all views holding any Binding from the ViewModel. The SwiftUI Form layout pass in the inspector then starves the MTKView of draw calls. Affected: all inspector tabs (Camera, Render, Cloud) when they take Bindings from the ViewModel. Fix approach: decouple inspector from ViewModel bindings - use plain values with explicit write-back callbacks, or extract inspector-editable state into a separate @Observable object that doesn't include rapidly-changing properties like cameraMatrix.
- `2026-04-02T20:21:37Z`: Proposed fix: Split ViewModel into two @Observable objects. 1) RenderState: rapidly-changing properties (cameraMatrix, currentFPS, sortEvents, frameCount). Only read by the render view, never bound to SwiftUI inspector views. 2) UIState: user-editable settings (cameraMode, backgroundColor, useSphericalHarmonics, showBoundingBoxes, debugMode, etc). Changed only by discrete user actions, safe to bind to SwiftUI forms. This prevents cross-contamination: cameraMatrix changing at 60fps only invalidates the render view, not the inspector. This is likely a general architectural pattern needed for any SwiftUI + Metal app that combines a render loop with SwiftUI controls.
- `2026-04-02T20:21:37Z`: this is a swiftui issue - use the swiftui instrument.

---

## 7: Remove 'Unified' prefix from type names

+++
status: closed
priority: low
kind: enhancement
created: 2026-03-03T00:00:00Z
closed: 2026-03-03T00:00:00Z
+++

The 'Unified' prefix on types like UnifiedDocumentView, UnifiedSplatContentView, UnifiedSplatViewModel, UnifiedInspectorView, UnifiedCameraContent, UnifiedRenderContent, UnifiedCloudInfoContent, UnifiedInspectorTab was an artifact of merging single and multi splat views. Now that they're merged, the prefix is redundant and makes names unnecessarily long. Rename to clearer, shorter names.

- `2026-04-02T20:21:37Z`: Also rename types with 'Content' suffix to use more descriptive names like Inspector, Editor, Detail. For example: UnifiedCameraContent -> CameraInspector, UnifiedRenderContent -> RenderInspector, UnifiedCloudInfoContent -> CloudInfoInspector, UnifiedSplatContentView -> SplatRenderView or similar.

---

## 8: Fix AsyncChannel send blocking: split event and indices sends into separate Tasks

+++
status: closed
priority: critical
kind: bug
created: 2026-03-05T00:00:00Z
updated: 2026-03-25T00:00:00Z
closed: 2026-03-25T00:00:00Z
+++

In AsyncSortManager.startSorting(), _sortEventChannel.send() and _sortedIndicesChannel.send() were in the same Task. If no consumer listened to the event channel, send() would suspend forever, blocking the indices send. Fixed by splitting into separate Tasks. Also moved sort listener startup from init() to onChange(initial: true) to avoid continuous re-sorting.

- `2026-04-02T20:21:37Z`: Resolved by replacing AsyncChannel with SingleValueStream and decoupling sort manager from render pipelines.

---

## 9: renderTargetArrayLength = 1 required on macOS due to visionOS cruft

+++
status: closed
priority: medium
kind: bug
labels: effort:s
created: 2026-03-05T00:00:00Z
updated: 2026-04-09T18:29:58Z
closed: 2026-04-09T18:29:58Z
+++

SparkSplatRenderPipeline requires .renderPassDescriptorModifier { $0.renderTargetArrayLength = 1 } on macOS. This is visionOS stereo rendering cruft leaking into macOS. Should be handled internally by the pipeline or MetalSprockets so callers don't need to set it.

- `2026-04-09T18:29:58Z`: Fixed: renderTargetArrayLength=1 now only applied on non-visionOS via #if. visionOS uses layered rendering with correct array length.

---

## 10: Add rendering unit tests with golden image comparisons

+++
status: open
priority: high
kind: task
labels: effort:l
created: 2026-03-05T00:00:00Z
updated: 2026-04-09T16:59:20Z
+++

We need unit tests that render splats via OffscreenRenderer and compare against golden images. Should cover: Spark renderer with test-grid fixture, Spark renderer with butterfly sample, different camera angles, SH on/off. Use the GoldenImage framework for comparisons.

---

## 11: Memory leak: AsyncChannel send Tasks accumulate holding Metal buffers

+++
status: closed
priority: high
kind: bug
labels: memory-leak, metal, async
created: 2026-03-09T00:00:00Z
closed: 2026-03-09T00:00:00Z
+++

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

- `2026-04-02T20:21:37Z`: Fixed by #12. The leak was caused by sortNowSync being called every frame from init, with each call creating a suspended Task holding a Metal buffer via the blocked _sortEventChannel send. Removing sortNowSync from init eliminates the per-frame buffer accumulation.

---

## 12: sortNowSync called in SparkSplatRenderPipeline.init runs every frame

+++
status: closed
priority: high
kind: bug
labels: performance
created: 2026-03-09T00:00:00Z
closed: 2026-03-09T00:00:00Z
+++

SparkSplatRenderPipeline.init calls sortManager.sortNowSync() to perform an initial sort. Because the struct is recreated every frame as part of the declarative render tree (inside the RenderView closure), this blocking synchronous sort runs every frame instead of once.

The initial sort should be moved to an .onChange(initial: true) handler that only triggers on first creation or when the splat cloud changes.

Same issue likely applies to Antimatter15SplatRenderPipeline and SparkSplatDebugRenderPipeline.

- `2026-04-02T20:21:37Z`: Moved sortNowSync out of init into onChange(initial: true) for all three render pipelines. sortedIndices is now optional, rendering skipped until first sort completes.

---

## 13: Stop using placeholder Metal debug labels

+++
status: open
priority: medium
kind: task
labels: effort:s
created: 2026-03-19T00:00:00Z
updated: 2026-04-09T16:59:20Z
+++

---

## 14: Make the splat renderers take sorted index buffers instead of sort managers.

+++
status: closed
priority: critical
kind: none
created: 2026-03-20T00:00:00Z
updated: 2026-03-25T00:00:00Z
closed: 2026-03-25T00:00:00Z
+++

- `2026-04-02T20:21:37Z`: Resolved by replacing AsyncChannel with SingleValueStream and decoupling sort manager from render pipelines.

---

## 15: Create docc docs for entire project.

+++
status: open
priority: medium
kind: documentation
labels: effort:l
created: 2026-03-25T00:00:00Z
updated: 2026-04-09T16:59:20Z
+++

---

## 16: Create a SplatView that hides sort manager complexity

+++
status: closed
priority: medium
kind: none
created: 2026-03-25T00:00:00Z
updated: 2026-03-31T20:31:19Z
closed: 2026-03-31T20:31:19Z
+++

Using the render pipelines directly requires the caller to manage the AsyncSortManager lifecycle, subscribe to sortedIndicesStream, request sorts on camera/model changes, and guard on nil sortedIndices before constructing the pipeline.

Create a high-level SplatView (SwiftUI) that encapsulates this pattern:
- Owns the AsyncSortManager internally
- Subscribes to sorted indices via .task
- Requests sorts on camera/model changes via .onChange
- Renders nothing until the first sort completes
- Exposes a simple API: pass in a splat cloud, camera, projection, model matrix, and drawable size

This would reduce the interactive rendering setup from ~20 lines to a single view.

- `2026-04-02T20:21:37Z`: Implemented SplatView in Sources/MetalSprocketsGaussianSplats/Spark/SplatView.swift. Owns AsyncSortManager internally, subscribes to sorted indices via .task, requests sorts on camera/model changes via .onChange, renders nothing until first sort completes. Updated demo ContentView to use it.

---

## 17: Move the larger demo into own repo.

+++
status: closed
priority: medium
kind: none
created: 2026-03-25T00:00:00Z
updated: 2026-03-30T00:00:00Z
closed: 2026-03-30T00:00:00Z
+++

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

+++
status: closed
priority: medium
kind: feature
created: 2026-03-27T00:00:00Z
closed: 2026-03-27T00:00:00Z
+++

Currently AsyncSortManager is initialised with a fixed set of GPUSplatClouds and cannot be retargeted. When switching between splats at runtime we have to create a new AsyncSortManager per cloud, which causes the sortedIndices to reset to nil on every switch — producing a blank frame and visible flicker.

We need a way to swap the active cloud(s) on an existing AsyncSortManager without recreating it. Something like:

    func setSplatClouds(_ clouds: [GPUSplatCloud<Splat>])

or a mutable splatClouds property. The sorter's internal MTLBuffer capacity would need to grow if the new cloud is larger than the original capacity.

- `2026-04-02T20:21:37Z`: Implemented setSplatClouds(_:) and setSplatCloud(_:) on AsyncSortManager. Added grow(capacity:) to CPUSplatRadixSorter. currentSortedIndices is preserved across cloud switches to prevent blank frames. Added 5 unit tests covering capacity growth, no-shrink, indices preservation, and correct sort count after switch.

---

## 19: Provide a lightweight one-shot sort helper for offline/offscreen rendering

+++
status: closed
priority: medium
kind: feature
created: 2026-03-27T00:00:00Z
updated: 2026-03-30T00:00:00Z
closed: 2026-03-30T00:00:00Z
+++

When rendering offscreen or in a single-frame context (e.g. snapshot, test, CLI tool), the full AsyncSortManager is overkill. It spins up a background task, manages streams, and holds actor state that is never needed for a single sort.

We should provide a simple public enum or struct SplatSorter with static sort methods that perform a synchronous, one-shot sort and return SplatIndices directly — no actor, no streams, no ongoing state.

API should look like:

    // Single cloud
    let indices = try SplatSorter.sort(device: device, splatCloud: cloud, parameters: sortParameters)

    // Multiple clouds
    let indices = try SplatSorter.sort(device: device, splatClouds: clouds, parameters: sortParameters)

CPUSplatRadixSorter already has internal static convenience methods (sort(device:splats:camera:model:reversed:) and sort(device:clouds:camera:sceneModel:reversed:)) that do the heavy lifting. SplatSorter should be a thin public wrapper over those.

- `2026-04-02T20:21:37Z`: Implemented SplatSorter as a public enum with two static sort methods wrapping CPUSplatRadixSorter. Handles empty cloud list gracefully. Added SplatSorterTests with 5 tests (all passing).

---

## 20: Adaptive sort algorithm: insertion sort for small camera deltas, radix sort fallback

+++
status: closed
priority: medium
kind: enhancement
labels: performance, sorting
created: 2026-03-30T00:00:00Z
updated: 2026-04-07T23:28:48Z
closed: 2026-04-07T23:28:48Z
+++

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

TL;DR: insertion-sort-from-previous-frame is ~1000x slower than radix sort for 100k+ splats under interactive rotation. The previous-frame permutation has ~13,700 inversions per element on the demo butterfly (149k splats), so the 'nearly sorted' premise doesn't hold. Hybrid mode (insertion with radix fallback) bails out every frame and is ~2x slower than radix-only due to wasted adaptive work.

Adaptive code and MSGS_ADAPTIVE_SORT instrumentation will be reverted in a follow-up commit; the timing log line is worth keeping.

- `2026-04-02T20:21:37Z`: ## Addendum: Timsort instead of insertion sort
- `2026-04-02T20:21:37Z`: ## Note on Timsort complexity
- `2026-04-02T20:21:37Z`: ## Buffer pooling enables copy-from-previous optimization
- `2026-04-07T23:28:48Z`: Experiment rejected. See RFC 0001 (RFCs/0001-adaptive-splat-sort.md) for full findings.

---

## 21: Rename gsplat-render to something less generic

+++
status: closed
priority: low
kind: enhancement
created: 2026-03-30T00:00:00Z
updated: 2026-04-07T21:49:32Z
closed: 2026-04-07T21:49:32Z
+++

The CLI tool is currently named 'gsplat-render' which is generic and could conflict with other Gaussian splat tools. Consider renaming to something that reflects its connection to MetalSprockets, e.g.:

- msplat-render
- metalgsplat
- sprocket-render
- ms-gsplat

The name should be short, memorable, and clearly associated with MetalSprocketsGaussianSplats.

---

## 22: Index/distance buffer pooling for sort manager

+++
status: closed
priority: medium
kind: feature
labels: performance, metal, sorting
created: 2026-03-31T15:58:34Z
updated: 2026-03-31T19:59:41Z
closed: 2026-03-31T19:59:41Z
+++

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

- `2026-04-02T20:21:37Z`: Implementation complete but blocked by MetalSprockets issue: `onCommandBufferCompleted` modifier does not fire. The pool infrastructure is in place and working, but buffer release cannot be wired up until MetalSprockets is fixed. See `releaseIndexBuffer(_:to:)` modifier in SparkSplatRenderPipeline.swift.
- `2026-04-02T20:21:37Z`: Blocked by MetalSprockets#290
- `2026-04-02T20:21:37Z`: Buffer pooling implemented and working. Buffers are released when new sorted indices arrive via `sortManager.release(old)`. See #26 for future ergonomics improvements.

---

## 23: Deprecate antimatter15 code

+++
status: closed
priority: low
kind: task
labels: cleanup, deprecation, effort:m
created: 2026-03-31T15:59:44Z
updated: 2026-04-09T22:56:21Z
closed: 2026-04-09T22:56:21Z
+++

The antimatter15 splat format and rendering code should be deprecated and eventually removed.

**Tasks:**

- `2026-03-31T15:59:44Z`: Mark antimatter15-related types and functions as deprecated
- `2026-03-31T15:59:44Z`: Add deprecation warnings/documentation
- `2026-03-31T15:59:44Z`: Identify all usages and plan migration path
- `2026-03-31T15:59:44Z`: Eventually remove the code once no longer needed
- `2026-04-09T22:56:21Z`: Done: all Antimatter15 code removed — types, render pipeline, reader, shaders, headers, tests, fixtures, CLI paths. IndexedDistance moved to SparkSplatRenderShader.h.

---

## 24: Mark stochastic and tile-based renderers as experimental

+++
status: closed
priority: low
kind: task
labels: documentation, api
created: 2026-03-31T15:59:58Z
updated: 2026-03-31T16:02:23Z
closed: 2026-03-31T16:02:23Z
+++

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

- `2026-03-31T15:59:58Z`: Important: This renderer/type is **experimental** and may have significant changes or be removed in future versions.
- `2026-04-02T20:21:37Z`: Added experimental documentation comments to all stochastic and tile-based renderer types:

---

## 25: AsyncSortManager.grow -> resize

+++
status: closed
priority: medium
kind: enhancement
labels: effort:xs
created: 2026-03-31T16:10:00Z
updated: 2026-04-09T20:32:10Z
closed: 2026-04-09T20:32:10Z
+++

- `2026-04-09T20:32:10Z`: Won't fix — grow only grows, renaming to resize without changing behavior would be misleading.

---

## 26: Simplify buffer release pattern for sortedIndicesStream consumers

+++
status: open
priority: low
kind: enhancement
labels: api, ergonomics, effort:m
created: 2026-03-31T19:59:36Z
updated: 2026-04-09T16:59:20Z
+++

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

+++
status: closed
priority: medium
kind: none
created: 2026-03-31T20:32:59Z
updated: 2026-04-09T16:57:35Z
closed: 2026-04-09T16:57:35Z
+++

- `2026-04-09T16:57:35Z`: Duplicate of #30

---

## 28: SplatIndices public init sets pool to nil causing silent release no-op

+++
status: closed
priority: medium
kind: bug
labels: effort:s
created: 2026-03-31T21:11:46Z
updated: 2026-04-09T20:30:24Z
closed: 2026-04-09T20:30:24Z
+++

The public init(parameters:indices:) on SplatIndices sets pool to nil, meaning release() on indices created outside of AsyncSortManager is a silent no-op. This is a footgun for callers constructing SplatIndices manually (e.g. tests, SplatSorter). Consider making the pool non-optional or removing the public init in favour of the internal one.

---

## 29: Replace local BUFFER macro with MetalSprocketsShaders import

+++
status: closed
priority: medium
kind: feature
created: 2026-04-02T19:15:41Z
updated: 2026-04-02T19:39:10Z
closed: 2026-04-02T19:39:10Z
+++

MetalSupport.h defines its own BUFFER macro and #ifdef __METAL_VERSION__ scaffolding. Replace with import from MetalSprocketsShaders, which now provides these cross-environment macros.

---

## 30: Get sample butterfly-wings-closed.spz working on visionOS headset in simple demo

+++
status: closed
priority: medium
kind: task
labels: effort:m
created: 2026-04-02T20:21:37Z
updated: 2026-04-09T18:29:58Z
closed: 2026-04-09T18:29:58Z
+++

- `2026-04-09T16:57:52Z`: Related: #27 closed as duplicate of this issue.
- `2026-04-09T17:41:00Z`: Basic implementation done: SplatImmersiveElement + SplatImmersiveRenderState render butterfly in immersive space. Demo updated with windowed SplatView + immersive space button. Remaining polish tracked in #35, #36, #37.
- `2026-04-09T18:29:58Z`: Done: SplatImmersiveElement + demo with windowed SplatView and immersive space. Remaining polish in #35, #36, #37.

---

## 31: Buffer pooling causes visual glitches when rotating demo butterfly

+++
status: closed
priority: medium
kind: none
created: 2026-04-07T22:18:08Z
updated: 2026-04-07T22:24:39Z
closed: 2026-04-07T22:24:39Z
+++

---

## 32: Splat buffer pool preallocation is one buffer too low

+++
status: closed
priority: medium
kind: none
created: 2026-04-07T23:16:01Z
updated: 2026-04-07T23:24:52Z
closed: 2026-04-07T23:24:52Z
+++

On startup of SplatView, a single `Pool exhausted, allocating new object (id: 5)` warning fires from the AsyncSortManager's index buffer pool.

The pool is currently preallocated with `pendingReleaseDepth + 2 = 5` buffers (see SplatView.swift), but the steady-state demand is one higher than that during the first few frames: the pending-release queue (3) + the in-flight sort buffer + the just-acquired buffer for the next sort = 5, plus apparently one more transient buffer in the very first frames.

Bumping `preallocatedBufferCount` from `pendingReleaseDepth + 2` to `pendingReleaseDepth + 3` should silence the warning.

Not a correctness issue — the pool grows on demand and stabilizes after the first allocation. Purely a startup-log-cleanliness fix.

Observed during the adaptive sort instrumentation work; see ~/Desktop/adaptive-sort-findings.md for the test runs that surfaced it.

---

## 33: Provide a simple enum / modifier to change SplatView renderer

+++
status: closed
priority: medium
kind: feature
created: 2026-04-09T17:00:29Z
updated: 2026-04-09T19:22:51Z
closed: 2026-04-09T19:22:51Z
+++

Add an enum for selecting the splat renderer (e.g. spark, stochastic, tile-based) and expose it as a SwiftUI modifier on SplatView.

- `2026-04-09T19:22:51Z`: Done: SplatRenderer enum (.spark, .stochastic) with .splatRenderer() SwiftUI modifier. SplatView reads from environment and switches renderer.

---

## 34: Add public SplatScene for visionOS immersive mode

+++
status: closed
priority: medium
kind: feature
labels: effort:l
created: 2026-04-09T17:03:09Z
updated: 2026-04-09T18:29:58Z
closed: 2026-04-09T18:29:58Z
+++

Provide a public RealityKit Scene (or ImmersiveSpace content) in the library that renders a splat cloud in visionOS immersive mode. This would let consumers drop in a splat immersive experience without wiring up Metal rendering manually. The simple demo (#30) can then just use this.

- `2026-04-09T17:41:05Z`: Partial: SplatImmersiveElement is the public reusable element, but it's not as turnkey as SplatView. Consumer must wire up ImmersiveRenderContent → ImmersiveRenderPass → SplatImmersiveElement manually. A convenience ImmersiveSpaceContent wrapper (like the original SplatImmersiveContent attempt) would make this a one-liner. See #37.
- `2026-04-09T18:29:58Z`: Done: SplatImmersiveElement and SplatImmersiveRenderState are the public API. Convenience wrapper tracked in #37.

---

## 35: Support per-eye sorting for visionOS stereo rendering

+++
status: new
priority: medium
kind: enhancement
labels: visionOS, sorting, effort:l
created: 2026-04-09T17:40:46Z
updated: 2026-04-09T18:02:11Z
+++

Currently SplatImmersiveElement sorts once using the left eye's camera matrix and shares the sorted index buffer for both eyes. For distant splats the depth order can differ between eyes, causing flicker. Since CPU sort is cheap (~2ms for 150k splats), we could sort twice — once per eye — using separate buffers. This would eliminate any depth-order disagreement between eyes.

- `2026-04-09T18:02:07Z`: More complex than expected. SparkSplatRenderPipeline uses vertex amplification — both eyes share a single draw call with one sort order. Per-eye sorting requires dropping vertex amplification and rendering each eye separately: two SparkSplatRenderPipeline elements, each with its own sort buffer, projection matrix, camera matrix, and render target layer. This is a meaningful rendering architecture change, not just two sort managers.

---

## 36: Investigate constant minor flicker in visionOS immersive rendering

+++
status: new
priority: medium
kind: bug
labels: effort:s, visionOS, sorting
created: 2026-04-09T17:40:54Z
updated: 2026-04-09T17:57:55Z
+++

Distant splats flicker during immersive rendering. Likely cause: the pending release depth (3 buffers) is too shallow for visionOS stereo rendering, which has more in-flight GPU work. A pool buffer may be returned and overwritten by a new sort while the GPU is still reading it. To diagnose: disable pool release entirely (just allocate fresh buffers) and see if flicker disappears. If confirmed, either increase the pending release depth for visionOS or make it configurable.

1. Sort instability from head tracking micro-movements: splats at similar depths swap order every frame as the camera position changes slightly. Gaussian splats are inherently sensitive to sort stability.
2. Alpha blending differences with rgba16Float (linear HDR) vs bgra8Unorm_srgb (8-bit sRGB): linear color space + alpha blending may behave differently for semi-transparent splats.
3. Sort using only eye 0 camera — minor depth order disagreements between eyes (unlikely to be the cause given small IPD vs splat depths).

The flicker is constant and minor, present even when head is relatively stationary (still tracked).

- `2026-04-09T17:52:31Z`: Pool reuse ruled out — disabling pool release did not fix the flicker. Remaining theories:
- `2026-04-09T17:57:50Z`: Pool reuse confirmed not the cause. Re-enabled pool release. Also tried averaged eye position (#39) — no change. Flicker remains open for further investigation.

---

## 37: Add turnkey SplatImmersiveContent convenience wrapper

+++
status: new
priority: medium
kind: enhancement
labels: effort:s, visionOS, api
created: 2026-04-09T17:41:13Z
+++

SplatImmersiveElement works but requires the consumer to set up ImmersiveRenderContent → ImmersiveRenderPass → SplatImmersiveElement + SplatImmersiveRenderState. SplatView is a single-line drop-in for windowed rendering — we should have the equivalent for immersive. A SplatImmersiveContent: ImmersiveSpaceContent that hides the boilerplate, so usage is just:

```swift
ImmersiveSpace(id: "Splat") {
    SplatImmersiveContent(splatCloud: cloud)
}
```

The earlier attempt failed due to the renderTargetArrayLength bug (now fixed via #if !os(visionOS) in SparkSplatRenderPipeline). Should be straightforward to reintroduce.

---

## 38: Immersive splat rendering looks washed out compared to windowed rendering

+++
status: closed
priority: medium
kind: bug
labels: effort:xs, visionOS
created: 2026-04-09T17:50:31Z
updated: 2026-04-09T17:57:41Z
closed: 2026-04-09T17:57:41Z
+++

The immersive butterfly appears dull and desaturated compared to the same splat rendered in a window. The windowed SplatView uses bgra8Unorm_srgb with convertSRGBToLinear: true (default). The immersive path uses rgba16Float (linear HDR) with convertSRGBToLinear: false. The splat color data is in sRGB, so when rendered into a linear framebuffer without conversion, colors are interpreted as linear values — making them appear washed out. Fix: set convertSRGBToLinear: true in SplatImmersiveElement.

- `2026-04-09T17:57:41Z`: Fixed: convertSRGBToLinear set to true in SplatImmersiveElement

---

## 39: Use averaged eye position for immersive sort camera

+++
status: closed
priority: low
kind: enhancement
labels: effort:xs, visionOS, sorting
created: 2026-04-09T17:51:37Z
updated: 2026-04-09T17:57:45Z
closed: 2026-04-09T17:57:45Z
+++

SplatImmersiveElement currently uses eye 0's camera matrix for sorting. Using the average of both eyes' positions would minimize worst-case sort error for either eye. Unlikely to fix the constant minor flicker but is more correct for stereo.

- `2026-04-09T17:57:45Z`: Implemented: averaging both eye positions for sort. Did not fix flicker but is more correct for stereo.

---

## 40: Demo app icon not showing on visionOS

+++
status: closed
priority: low
kind: bug
labels: effort:s, visionOS, demo
created: 2026-04-09T18:09:00Z
updated: 2026-04-09T19:13:38Z
closed: 2026-04-09T19:13:38Z
+++

The demo has an AppIcon.icon file (Icon Composer format) but no icon appears. Icon Composer .icon files only support iOS, iPadOS, macOS, and watchOS. visionOS (and tvOS) require layered image stacks in the asset catalog. The demo needs either a visionOS-specific AppIcon.solidimagestack in Assets.xcassets, or at minimum a fallback single-layer icon in the asset catalog.

- `2026-04-09T19:13:38Z`: Added AppIcon.solidimagestack to asset catalog. Back layer opacity fixed with imagemagick. Filed icon-generator bug (icon-generator#10).

---

## 41: Splat rendering fails silently in visionOS and iPad simulators

+++
status: new
priority: low
kind: bug
labels: effort:m, simulator
created: 2026-04-09T19:09:47Z
+++

SplatView renders nothing in visionOS and iPad simulators — sorting runs but no pixels appear. No errors logged. Works fine on device and on macOS native. The MetalSprockets cube demo renders fine on simulator, so it's specific to the splat pipeline. Likely cause: GPU buffer addresses (gpuAddressAsUnsafeMutablePointer), argument buffers, or other advanced Metal features used by SparkSplatRenderPipeline that aren't supported by simulator Metal.

- `2026-04-09T19:16:07Z`: Root cause found: 'pointers to an argument buffer inside another argument buffer are not supported in the simulator'. SparkSplatRenderPipeline uses nested argument buffers (MultiCloudArgumentBuffer → SplatCloudData → GPU buffer pointers). This is a simulator Metal limitation, not fixable without restructuring the shader argument passing.

---

## 42: Add MetalSprockets FPS counter to demo

+++
status: closed
priority: low
kind: enhancement
labels: effort:xs, demo
created: 2026-04-09T19:17:42Z
updated: 2026-04-09T19:53:34Z
closed: 2026-04-09T19:53:34Z
+++

The MetalSprockets FrameTimingView provides an FPS overlay. Add it to the demo app for both windowed and immersive rendering to help diagnose performance issues.

---

## 43: Add ARKit camera passthrough mode to iOS demo

+++
status: new
priority: low
kind: feature
labels: effort:m, demo, iOS
created: 2026-04-09T19:19:51Z
+++

The MetalSprockets demo has an ARKit mode that renders the camera feed (YCbCr billboard) with 3D content overlaid using ARKit world tracking. Add similar support to the splat demo on iOS — render splats on top of the AR camera feed with proper AR projection/view matrices from ARKit. See MetalSprockets Example MobileDemoView for the pattern: ARSessionDelegate + .arkit() modifier + YCbCrBillboardRenderPass.

---

## 44: Investigate why stochastic renderer requires depth buffer

+++
status: closed
priority: low
kind: bug
labels: effort:s, stochastic
created: 2026-04-09T20:05:59Z
updated: 2026-04-09T20:41:51Z
closed: 2026-04-09T20:41:51Z
+++

Switching to stochastic mode in SplatView crashes with 'MTLDepthStencilDescriptor sets depth test but MTLRenderPassDescriptor has a nil depthAttachment texture'. The stochastic renderer shouldn't need depth testing — it uses stochastic alpha sampling. Something in the pipeline or MetalSprockets is setting up depth state unexpectedly. Currently worked around by setting .metalDepthStencilPixelFormat(.depth32Float) when in stochastic mode.

- `2026-04-09T20:39:41Z`: Confirmed: stochastic shader and pipeline don't reference depth at all. The depth error comes from MetalSprockets applying a default depth state somewhere. The .metalDepthStencilPixelFormat(.depth32Float) workaround in SplatView is masking a MetalSprockets issue, not a real stochastic requirement.
- `2026-04-09T20:41:45Z`: Stochastic algorithm itself (random alpha thresholding) doesn't use depth. But depth testing IS required for front-to-back occlusion — without it, distant splats overwrite closer ones that already passed the stochastic coin flip. The depth buffer serves as an 'already filled' mask. So the depth requirement is correct, just not for the reason originally assumed.
- `2026-04-09T20:41:51Z`: Resolved: depth is needed for front-to-back occlusion. Current workaround (.metalDepthStencilPixelFormat when stochastic) is correct.

---

## 45: SplatView renders blank when used with .toolbar or NavigationStack on macOS

+++
status: new
priority: medium
kind: bug
labels: effort:xs, macOS, demo
created: 2026-04-09T20:07:10Z
+++

SplatView (via RenderView/MTKView) renders nothing when .toolbar is applied or when wrapped in NavigationStack on macOS. Resizing the window triggers rendering. Root cause is in MetalSprockets (filed as MetalSprockets#311) — MTKView gets zero initial size and never redraws. Workaround: use .overlay for UI controls instead of .toolbar.

---

## 46: Add tile-based renderer to SplatRenderer enum

+++
status: new
priority: low
kind: enhancement
labels: effort:m, tile-based
created: 2026-04-09T20:08:11Z
+++

SplatRenderer currently has .spark and .stochastic but not .tileBased. TileBasedSplatPipeline requires TileSplatResources to be created and managed, so it's not a trivial drop-in. SplatView would need to lazily create and hold TileSplatResources when tile-based mode is selected.

---

## 47: SplatView still sorts in stochastic mode

+++
status: closed
priority: medium
kind: bug
labels: effort:s, stochastic, performance
created: 2026-04-09T20:08:30Z
updated: 2026-04-09T20:10:24Z
closed: 2026-04-09T20:10:24Z
+++

When SplatView is set to .stochastic renderer, the AsyncSortManager continues sorting every frame even though the stochastic renderer doesn't use sorted index buffers. SplatView should skip sort requests (and ideally pause the sort manager) when the active renderer doesn't need sorting.

- `2026-04-09T20:10:24Z`: Fixed: sort requests are skipped when renderer != .spark. Sort is re-triggered when switching back to spark.

---

## 48: Support magnify gesture and scroll wheel for camera zoom in demo

+++
status: closed
priority: medium
kind: enhancement
labels: effort:m, demo
created: 2026-04-09T20:09:00Z
updated: 2026-04-09T20:23:49Z
closed: 2026-04-09T20:23:49Z
+++

The demo only supports turntable drag rotation via .interactiveCamera(). Add pinch-to-zoom (MagnifyGesture) on iOS/visionOS and scroll wheel zoom on macOS. This may need changes in Interaction3D or custom gesture handling in the demo.

- `2026-04-09T20:23:49Z`: Already supported — Interaction3D's InteractiveCameraModifier includes MagnifyGesture (pinch-to-zoom) and .onScrollWheel (macOS scroll wheel) out of the box.

---

## 49: Metal GPU performance HUD disappears during drag/pan gestures

+++
status: new
priority: low
kind: bug
labels: effort:xs, macOS
created: 2026-04-09T20:13:18Z
+++

The Metal GPU performance overlay disappears while dragging/panning the camera. Reappears when gesture ends. Same issue as MetalSprockets#34/#312. Flickering is reduced when shader validation is enabled (slower frame rate). Likely a SwiftUI overlay/z-ordering issue during gesture handling in RenderView.

---

## 50: Support stochastic renderer in visionOS immersive mode

+++
status: closed
priority: low
kind: feature
labels: visionOS, stochastic, effort:s
created: 2026-04-09T20:13:29Z
updated: 2026-04-09T21:29:56Z
closed: 2026-04-09T21:29:56Z
+++

SplatImmersiveElement currently only uses SparkSplatRenderPipeline. Add support for switching to StochasticSplatRenderPipeline in immersive mode, which would eliminate the need for sorting entirely on visionOS. Would need to handle the depth buffer requirement and stereo rendering setup for stochastic mode.

- `2026-04-09T20:44:44Z`: Stochastic pipeline has no vertex amplification support — shader and pipeline are mono only. Needs: 1) amplification_id/render_target_array_index in shader vertex output 2) per-eye view/projection matrix arrays in pipeline 3) maxVertexAmplificationCount on render pipeline descriptor 4) reverse-Z depth handling for visionOS. Same stereo work Spark already has, ported to stochastic.
- `2026-04-09T21:29:56Z`: Done: SplatImmersiveElement accepts renderer parameter. Stochastic pipeline updated with stereo amplification support. Depth compare moved to caller (reverse-Z on visionOS, standard on macOS/iOS). Demo shares renderer state between windowed and immersive via DemoState.

---

## 51: Investigate stochastic seed behavior when camera is stationary

+++
status: new
priority: low
kind: enhancement
labels: effort:s, stochastic
created: 2026-04-09T20:13:57Z
+++

Currently frameTime (frame counter) is passed as the stochastic seed every frame, so the noise pattern changes even when the camera isn't moving. This causes constant visual shimmer. When the camera is stationary, we could either freeze the seed (stable but noisy image) or accumulate/average multiple frames for temporal convergence. Need to investigate what looks best.

---

## 52: Hide windowed SplatView when immersive space is active

+++
status: closed
priority: medium
kind: enhancement
labels: effort:xs, demo, visionOS
created: 2026-04-09T21:46:47Z
updated: 2026-04-09T21:55:41Z
closed: 2026-04-09T21:55:41Z
+++

When the user enters immersive mode, the windowed SplatView keeps rendering in the background — wasting GPU/CPU on sorting and rendering that isn't visible. The windowed content should be replaced with a placeholder or hidden when the immersive space is open.

- `2026-04-09T21:55:41Z`: Done: SplatView replaced with Color.clear when immersive mode is active. Ornament with picker and toggle stays visible.

---

## 53: Add render stats overlay for immersive mode

+++
status: closed
priority: low
kind: enhancement
labels: effort:m, visionOS, demo
created: 2026-04-09T21:48:27Z
updated: 2026-04-09T22:32:36Z
closed: 2026-04-09T22:32:36Z
+++

FrameTimingView is available for windowed SplatView via .onFrameTimingChange but there's no equivalent for the immersive CompositorServices render loop. Would be useful to have FPS/frame timing stats visible in immersive mode for performance debugging.

- `2026-04-09T21:58:31Z`: Root cause is MetalSprockets — ImmersiveRuntime doesn't expose frame timing. Filed MetalSprockets#313. Can work around by tracking timestamps in SplatImmersiveRenderState but proper fix belongs upstream.
- `2026-04-09T22:32:36Z`: Done: using MetalSprockets .onFrameTimingChange on ImmersiveRenderContent. FrameTimingView shown in ornament when immersive mode is active.

---

## 54: Support gestures in visionOS immersive mode

+++
status: new
priority: medium
kind: feature
labels: effort:m, visionOS, demo
created: 2026-04-09T21:57:38Z
+++

The immersive splat currently has no gesture interaction — the splat is static in space. Add gesture support for manipulating the splat in immersive mode.

---

## 55: Generate both macOS (.icon) and visionOS (.solidimagestack) app icons from same content

+++
status: closed
priority: low
kind: task
labels: effort:s, demo
created: 2026-04-09T22:00:25Z
updated: 2026-04-09T22:02:16Z
closed: 2026-04-09T22:02:16Z
+++

The demo currently has separate AppIcon.icon (macOS/iOS) and AppIcon.solidimagestack (visionOS) that were generated independently. Should generate both from the same source content to keep them consistent. Could use icon-generator to produce both formats in one step.

- `2026-04-09T22:02:16Z`: Done: both .icon and .solidimagestack generated with butterfly emoji on dark purple gradient/background.

---

## 56: GPU-sorted pipeline does not support stereo/visionOS rendering

+++
status: new
priority: medium
kind: feature
labels: visionOS
created: 2026-07-20T18:42:44Z
+++

GPUSortedSplatRenderPipeline and GPUSplatSortComputePass take a single projection/camera matrix and render mono only. SparkSplatRenderPipeline supports vertex amplification with per-view matrices, but the GPU sort path has no way to express stereo: the cull uses one projection matrix, so splats visible to only one eye could be culled incorrectly, and the pipeline exposes no multi-matrix initializer. visionOS immersive rendering therefore cannot use the GPU sort path.

---

## 57: SplatImmersiveContent should be able to use the GPU sort pipeline

+++
status: new
priority: low
kind: enhancement
labels: visionOS
created: 2026-07-20T18:42:44Z
+++

SplatImmersiveContent drives immersive visionOS rendering via the CPU AsyncSortManager path. Once stereo support exists in the GPU-sorted pipeline, immersive content should be able to opt into GPU sorting/culling, removing CPU sort latency in head-tracked rendering where stale sort order is most visible.

---

## 58: Tile-based renderer performance is poor

+++
status: new
priority: medium
kind: bug
labels: tile-based
created: 2026-07-20T18:53:32Z
+++

The tile-based renderer runs significantly slower than the Spark and GPU-sorted renderers on the same scenes (observed in the demo app on macOS). Frame times are noticeably worse when switching the Renderer picker to Tile.

---

## 59: Tile-based renderer blending is broken - output is washed out

+++
status: closed
priority: medium
kind: bug
labels: tile-based
created: 2026-07-20T18:53:32Z
updated: 2026-07-21T15:08:16Z
closed: 2026-07-21T15:08:16Z
+++

With the tile-based renderer selected, the butterfly model renders washed out compared to the Spark renderer on the same scene: colors are pale and low-contrast, as if alpha accumulation or the sRGB/linear conversion in the tile shader's front-to-back blend is wrong.

Repro:
1. Run MetalSprocketsGaussianSplatsDemo on macOS
2. Select the Butterfly model
3. Switch Renderer between Spark and Tile

Expected: matching color/contrast. Actual: Tile output is visibly washed out.

- `2026-07-21T15:08:17Z`: Tile fragment re-encoded linear back to sRGB before writing to the sRGB render target, double-encoding on store. Now writes linear and lets the target encode.

---

## 60: Investigate reusing GPU pipeline frustum cull in tile-based renderer

+++
status: closed
priority: low
kind: enhancement
labels: tile-based
created: 2026-07-20T18:53:32Z
updated: 2026-07-20T18:55:19Z
closed: 2026-07-20T18:55:19Z
+++

The GPU-sorted pipeline (SplatGPUSort) culls splats against the frustum before sorting, so downstream passes only process survivors. The tile-based renderer bins every splat with no pre-cull. Investigate whether running the same cull ahead of binning improves tile-based performance and/or the washed-out blending (fewer overlapping contributions per tile).

- `2026-07-20T18:55:19Z`: Not needed: the binning kernel already culls — splats behind the camera, off-screen, or below the alpha threshold return false from tile-bounds computation and never produce tile entries. A separate pre-cull/compact pass would itself be a full per-splat pass, so it would roughly break even on binning cost, and it cannot affect the washed-out blending (#59), which is an ordering/accumulation problem within visible tiles.

---

## 61: Investigate using SplatGPUSort radix sort for tile-based per-tile ordering

+++
status: new
priority: low
kind: enhancement
labels: tile-based
created: 2026-07-20T18:53:32Z
+++

The GPU-sorted pipeline has a proper stable two-pass 8-bit radix sort over the half depth key (SplatGPUSort). The tile-based renderer uses its own per-tile sort (TileSplatSort). Investigate whether the per-tile depth ordering is currently incorrect or unstable (a possible contributor to the washed-out blending) and whether the SplatGPUSort radix approach could replace or feed the per-tile sort.

- `2026-07-20T18:58:32Z`: Findings from code review (2026-07-20):

tile_sort (TileSplatSort.metal) is one thread per tile running a serial 4-pass 8-bit radix: 8 full walks of the tile's list (histogram + scatter x 4 passes) with a 256-entry thread-private histogram. Dense tiles serialize on a single thread — likely the bulk of the poor performance in #58. A 32-bit key is also overkill for depth ordering.

Preferred direction (classic 3DGS pipeline, as in the original CUDA implementation): drop the per-tile sort pass entirely and globally sort the binned tile entries (splat-tile pairs) with a combined key (tileID << 16) | flippedHalfDepth, using the cooperative SplatGPUSort radix already in the codebase (4 x 8-bit passes for the 32-bit key). Entries come out grouped by tile (contiguous, matching existing tileOffsets ranges) and depth-ordered within each tile. Per-tile imageblock rendering is unchanged — the range just arrives pre-sorted.

Note: this is a sort of the binned entries, not the splats — a splat overlapping N tiles appears N times with different tileID keys.

May also be relevant to #59: guarantees a stable, correct front-to-back order per tile (the current kernel sorts descending via key inversion; worth verifying direction against the renderer's expectation).

Related: #58, #59.

---

## 62: Unified splat pipeline: shared cull + global sort front-end feeding tile-based rendering

+++
status: new
priority: medium
kind: feature
labels: tile-based
created: 2026-07-20T19:01:34Z
+++

The GPU-sorted pipeline (SplatGPUSort) and the tile-based renderer are converging on the same front-end tools: frustum cull, depth keys, radix sort. They differ only in back-end — sorted instanced quads with hardware blending (Spark/GPU) vs per-pixel front-to-back imageblock accumulation with early termination (tile).

In practice overdraw is extreme in typical splat scenes, so the Spark/GPU path pays heavily in blend bandwidth. The tile back-end is the structural cure (early termination kills overdraw per pixel), but today it loses everywhere because of its serial per-tile sort (#61) and blending bugs (#59), with overall poor performance (#58).

Target architecture: one shared front-end — cull (from SplatGPUSort), bin, global radix sort of tile entries keyed (tileID, depth) — feeding the per-tile imageblock renderer. The existing quad back-end remains as a consumer of the same cull + depth-sort passes.

Related: #58 (tile perf), #59 (tile blending), #61 (global tile|depth sort replacing per-tile sort).

- `2026-07-20T19:45:10Z`: RFC 0002 (RFCs/0002-tilealt-cull-globalsort-bin-render.md) proposes TileAlt: cull -> global depth sort -> ordered (atomics-free) bin -> stable tileID partition -> tile render, as a sibling of the existing tile renderer. Depends on MetalSprockets#351 (indirect compute dispatch).

---

## 63: PointSplat: splat stage dispatches over full point budget instead of actual count

+++
status: closed
priority: high
kind: none
labels: performance, pointsplat
created: 2026-07-21T14:52:10Z
updated: 2026-07-21T17:57:49Z
closed: 2026-07-21T17:57:49Z
+++

The splat kernel is dispatched over maxPointsPerFrame (default 4M) threads every frame because the total point count only exists GPU-side; threads past totals[0] exit immediately. Wasteful for sparse frames. MetalSprockets doesn't expose dispatchThreadgroups(indirectBuffer:) (same gap noted in RFC 0002). Affects both PointSplatRenderer and PointSplatRenderPipeline.

- `2026-07-21T16:32:51Z`: Now that the point budget auto-scales with drawable size (32/supersampled pixel, ~500M on large drawables), the capacity-sized splat dispatch is the dominant fixed cost. Either expose indirect dispatch in MetalSprockets or clamp thread count another way.
- `2026-07-21T17:57:49Z`: All post-prefix-sum stages (index clear, max-scan, carry apply, splat) now dispatch indirectly from the GPU-side total via dispatchThreadgroups(indirectBuffer:), encoded raw inside the compute pass. Per-frame cost scales with actual point demand instead of the budget ceiling.

---

## 64: PointSplat: no spherical harmonics support

+++
status: closed
priority: medium
kind: none
labels: pointsplat
created: 2026-07-21T14:52:10Z
updated: 2026-07-21T15:17:45Z
closed: 2026-07-21T15:17:45Z
+++

PointSplat renders base splat color only; view-dependent SH color (used by Spark and Stochastic renderers) is ignored. Scenes with SH will look flat compared to other renderers in the demo picker.

- `2026-07-21T15:17:45Z`: SH evaluated once per Gaussian in the preprocess kernel (view direction to the mean), cached as packed 36-bit color for the splat stage. Verified visually against Spark.

---

## 65: PointSplat: measure simdgroup dedupe before atomic_min

+++
status: new
priority: low
kind: none
labels: performance, pointsplat
created: 2026-07-21T14:52:10Z
+++

The splat kernel has an early depth test (plain aliased read) before atomic_min, but no simdgroup-level dedupe of points targeting the same pixel (Schuetz 2021 reports large wins from warp dedupe under contention). Unknown whether it pays off on Apple GPUs; needs measurement with GPU capture on close-up views.

---

## 66: PointSplat: profile occupancy, atomic throughput, and scaling vs sorted pipelines

+++
status: new
priority: medium
kind: none
labels: performance, pointsplat
created: 2026-07-21T14:52:10Z
+++

RFC 0003 verification plan items not yet done: GPU capture to confirm even occupancy across the splat dispatch (the paper's central claim) and atomic throughput; record the frame-time scaling curve vs Spark/GPU/Stochastic on small and multi-million-splat scenes.

---

## 67: PointSplat: near/far planes hardcoded in interactive pipeline

+++
status: new
priority: medium
kind: none
labels: pointsplat
created: 2026-07-21T14:52:10Z
+++

PointSplatRenderPipeline hardcodes nearPlane 0.2 / farPlane 200 for the 28-bit fixed-point depth quantization, ignoring the projection's zClip range. Scenes larger than 200 units or with tighter near planes will quantize depth badly. RFC 0003 open question 2 (reversed-infinite-Z reconciliation) is also unresolved.

---

## 68: PointSplat: color space of blit presentation unverified

+++
status: closed
priority: high
kind: none
labels: bug, pointsplat
created: 2026-07-21T14:52:11Z
updated: 2026-07-21T15:08:17Z
closed: 2026-07-21T15:08:17Z
+++

The resolve/accumulation textures hold raw (sRGB-encoded) splat color values in rgba16Float; the fullscreen BlitShader samples them and writes into a bgra8Unorm_srgb drawable, which will re-encode. PointSplat output may look washed out or double-encoded next to the other renderers in the demo picker. Needs a visual A/B check.

- `2026-07-21T14:58:20Z`: Visual A/B done: PointSplat is washed out in the same way as the tile renderer (#59), so this is the shared color-pipeline issue rather than a PointSplat-specific double-encode. Keeping open until #59 is understood.
- `2026-07-21T15:08:17Z`: Same double-encode class as #59: PointSplat blit sampled sRGB-encoded accumulation values into an sRGB drawable. Blit fragment now linearizes (function constant on BlitShader). Visually verified against Spark.

---

## 69: PointSplat: occlusion culling and temporal reprojection deferred

+++
status: closed
priority: low
kind: none
labels: pointsplat
created: 2026-07-21T14:52:11Z
updated: 2026-07-21T19:07:30Z
closed: 2026-07-21T19:07:30Z
+++

RFC 0003 defers hierarchical/occlusion culling (two-phase scheme, depth mip chain) and reprojection-based temporal reuse. Without them, large occluded scenes waste splat work, and any camera motion resets accumulation to 1 SPP noise. Tracking issue for the follow-up.

- `2026-07-21T19:06:12Z`: Occlusion culling half implemented (WIP commit d9fde5d7): hierarchical max-depth pyramid, two-phase cull per the paper. Known render issues being debugged. Temporal reprojection not started.
- `2026-07-21T19:07:30Z`: Occlusion culling implemented (two-phase hierarchical depth cull, WIP commit d9fde5d7 - render issues being debugged in follow-up work). Temporal reprojection split out to #73.

---

## 70: Parallel code paths for offscreen vs live rendering

+++
status: new
priority: medium
kind: none
created: 2026-07-21T17:47:37Z
+++

Offscreen and live rendering have largely parallel/duplicated code paths. Needs a dramatic cleanup to consolidate the shared logic.

---

## 71: SOGReaderCPU: ImageIO rejects some lossless WebP textures

+++
status: new
priority: medium
kind: bug
labels: splats
created: 2026-07-21T18:07:20Z
+++

Loading sphere-32M.sog fails with failedToDecodeImage(quats.webp). The file is a valid 5660x5656 VP8L (lossless) WebP, 1.3 KB (constant-color, likely all-identity quaternions); CGImageSource creates a source but CGImageSourceCreateImageAtIndex returns nil, while the sibling scales.webp (same dims, also from the same encoder) decodes fine. sips can't read its dimensions either, so this is an ImageIO WebP decoder limitation, not a parsing bug in the reader. Affects SOG files from encoders that emit highly-compressed lossless textures. Possible fix: bundle a small VP8L decoder or special-case via libwebp.

- `2026-07-21T18:12:42Z`: Characterized: ImageIO fails on lossless WebP using the VP8L color-indexing (palette) transform when the palette contains alpha and the image is large (fails at >=4095x4095, works at <=2048x2048; opaque palettes work at all sizes; libwebp decodes everything fine). Reproduced with synthetic cwebp -lossless encodes, so it's not specific to the SOG encoder. Tested on macOS 27 beta - possibly a beta ImageIO regression; worth a feedback report. Workaround options: decode via libwebp for VP8L+palette+alpha, or pre-process textures.

---

## 72: Port GPU SOG reader from gaussiansplats-ios

+++
status: closed
priority: high
kind: enhancement
labels: splats, performance
created: 2026-07-21T18:35:05Z
updated: 2026-07-21T18:40:09Z
closed: 2026-07-21T18:40:09Z
+++

Loading large SOG files (e.g. sphere-48M.sog) through SOGReaderCPU takes minutes: per-splat Swift closure over 48M splats plus huge intermediate GenericSplat/ExtendedSplat arrays before the GPU buffer is built. ~/Shared/Projects/Work/gaussiansplats-ios has a GPU path to port: Sources/GaussianSplatMetal/IO/SOGReaderGPU.swift (unzips, decodes the WebP planes concurrently into rgba8Uint textures) + Sources/GaussianSplatShaders/SOGDecodeShader.metal (compute kernel dequantizes per splat straight into a SparkSplat buffer and flattened SH buffer) + SplatCloudBuilder + its MiniZip dependency. Produces the same SparkSplat layout we use. Note: it still decodes WebP via ImageIO, so it does not address #71 (palette+alpha decode failure); large generated files may need both fixes. The demo already parses off-main with a loading indicator, so this slots in behind the existing loadCustomSplat path.

- `2026-07-21T18:40:09Z`: Ported SOGReaderGPU + SOGDecodeShader from gaussiansplats-ios (adapted to ZIPFoundation and this repo's shader bundle lookup). Parity test vs SOGReaderCPU on test-ring.sog passes. Demo loads all .sog files (bundled helmet + custom loads) through the GPU path.

---

## 73: PointSplat: temporal reprojection for camera motion

+++
status: closed
priority: low
kind: feature
labels: pointsplat
created: 2026-07-21T19:07:30Z
updated: 2026-07-21T19:41:31Z
closed: 2026-07-21T19:41:31Z
+++

Accumulation resets to 1 SPP noise the moment the camera moves. The paper's reprojection (Sec 3.6) warps the previous accumulated frame into the new view using last frame's depth and view-projection matrices, clamps against the 3x3 color neighborhood to limit ghosting, and blends with EMA weight 0.9. They call it basic and prone to detail loss; a proper spatiotemporal denoiser would do better. Split out from #69.

- `2026-07-21T19:41:31Z`: Reprojection implemented per paper Sec 3.6: warp previous accumulation via min-subpixel-depth world reconstruction and previous view-projection, 3x3 neighborhood color clamp, 0.9 history EMA. Static views keep the exact running mean; model swaps hard-reset.

---

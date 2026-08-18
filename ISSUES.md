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
labels: effort:m, punted
created: 2026-02-19T00:00:00Z
updated: 2026-07-21T22:48:16Z
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

- `2026-07-21T21:32:44Z`: Investigated in current codebase: the SwiftUI bounding-box overlay described here no longer exists (only SparkSplatDebugRenderPipeline remains, which draws bounds inside the same Metal pass, so it cannot lag relative to the splats). The underlying mechanism (RenderView content closure sampling cameraMatrix at render time, potentially behind gesture-rate SwiftUI updates) still exists but has no visible artifact without the overlay, and all three proposed fixes live in MetalSprockets' RenderView (setNeedsDisplay on state change / observing state). Unblocker: either close as obsolete, or re-file against MetalSprockets so RenderView redraws (or re-samples state) when observed content state changes.

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
priority: low
kind: bug
labels: effort:xl, not-testable
created: 2026-02-20T00:00:00Z
updated: 2026-07-21T22:29:46Z
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
status: closed
priority: high
kind: task
labels: effort:l
created: 2026-03-05T00:00:00Z
updated: 2026-07-21T20:57:00Z
closed: 2026-07-21T20:57:00Z
+++

We need unit tests that render splats via OffscreenRenderer and compare against golden images. Should cover: Spark renderer with test-grid fixture, Spark renderer with butterfly sample, different camera angles, SH on/off. Use the GoldenImage framework for comparisons.

- `2026-07-21T20:57:00Z`: Added golden-image rendering tests: test-grid alternate camera angle, butterfly sample (resolved from Samples/ via #filePath, with SH), and butterfly SH-on vs SH-off with a guard asserting SH actually changes the image (test-ring.sog turned out to carry no SH, which would have made the test vacuous).

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
status: closed
priority: medium
kind: task
labels: effort:s, not-testable
created: 2026-03-19T00:00:00Z
updated: 2026-07-21T21:33:47Z
closed: 2026-07-21T21:33:47Z
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
status: closed
priority: medium
kind: documentation
labels: effort:l
created: 2026-03-25T00:00:00Z
updated: 2026-07-21T21:58:57Z
closed: 2026-07-21T21:58:57Z
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
status: closed
priority: low
kind: enhancement
labels: api, ergonomics, effort:m
created: 2026-03-31T19:59:36Z
updated: 2026-07-21T22:35:56Z
closed: 2026-07-21T22:35:56Z
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
status: closed
priority: medium
kind: enhancement
labels: visionOS, sorting, effort:l, not-testable
created: 2026-04-09T17:40:46Z
updated: 2026-07-21T21:37:23Z
closed: 2026-07-21T21:37:23Z
+++

Currently SplatImmersiveElement sorts once using the left eye's camera matrix and shares the sorted index buffer for both eyes. For distant splats the depth order can differ between eyes, causing flicker. Since CPU sort is cheap (~2ms for 150k splats), we could sort twice — once per eye — using separate buffers. This would eliminate any depth-order disagreement between eyes.

- `2026-04-09T18:02:07Z`: More complex than expected. SparkSplatRenderPipeline uses vertex amplification — both eyes share a single draw call with one sort order. Per-eye sorting requires dropping vertex amplification and rendering each eye separately: two SparkSplatRenderPipeline elements, each with its own sort buffer, projection matrix, camera matrix, and render target layer. This is a meaningful rendering architecture change, not just two sort managers.

---

## 36: Investigate constant minor flicker in visionOS immersive rendering

+++
status: open
priority: medium
kind: bug
labels: effort:s, visionOS, sorting, not-testable, punted
created: 2026-04-09T17:40:54Z
updated: 2026-07-21T22:48:16Z
+++

Distant splats flicker during immersive rendering. Likely cause: the pending release depth (3 buffers) is too shallow for visionOS stereo rendering, which has more in-flight GPU work. A pool buffer may be returned and overwritten by a new sort while the GPU is still reading it. To diagnose: disable pool release entirely (just allocate fresh buffers) and see if flicker disappears. If confirmed, either increase the pending release depth for visionOS or make it configurable.

1. Sort instability from head tracking micro-movements: splats at similar depths swap order every frame as the camera position changes slightly. Gaussian splats are inherently sensitive to sort stability.
2. Alpha blending differences with rgba16Float (linear HDR) vs bgra8Unorm_srgb (8-bit sRGB): linear color space + alpha blending may behave differently for semi-transparent splats.
3. Sort using only eye 0 camera — minor depth order disagreements between eyes (unlikely to be the cause given small IPD vs splat depths).

The flicker is constant and minor, present even when head is relatively stationary (still tracked).

- `2026-04-09T17:52:31Z`: Pool reuse ruled out — disabling pool release did not fix the flicker. Remaining theories:
- `2026-04-09T17:57:50Z`: Pool reuse confirmed not the cause. Re-enabled pool release. Also tried averaged eye position (#39) — no change. Flicker remains open for further investigation.
- `2026-07-21T21:37:32Z`: Per-eye sorting is now implemented (#35): each eye gets its own sort order and draw call, removing theory 3 (eye-0-only sort / averaged-eye sort) as a variable. Cannot verify on-device from this environment — needs a Vision Pro test. If flicker persists after #35, remaining theories are (1) Float16 sort-key quantization: distanceToCamera is Float16, so head micro-movements push splats across quantization boundaries, reordering them within blend order (try widening the sort key to Float32/UInt32 in IndexedDistance), and (2) rgba16Float linear blending differences. Unblocker: on-device retest with per-eye sorting, then try a 32-bit sort key if still flickering.

---

## 37: Add turnkey SplatImmersiveContent convenience wrapper

+++
status: closed
priority: medium
kind: enhancement
labels: effort:s, visionOS, api, not-testable
created: 2026-04-09T17:41:13Z
updated: 2026-07-21T21:34:32Z
closed: 2026-07-21T21:34:32Z
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
status: closed
priority: low
kind: bug
labels: effort:m, simulator
created: 2026-04-09T19:09:47Z
updated: 2026-07-22T03:05:29Z
closed: 2026-07-22T03:05:29Z
+++

SplatView renders nothing in visionOS and iPad simulators — sorting runs but no pixels appear. No errors logged. Works fine on device and on macOS native. The MetalSprockets cube demo renders fine on simulator, so it's specific to the splat pipeline. Likely cause: GPU buffer addresses (gpuAddressAsUnsafeMutablePointer), argument buffers, or other advanced Metal features used by SparkSplatRenderPipeline that aren't supported by simulator Metal.

- `2026-04-09T19:16:07Z`: Root cause found: 'pointers to an argument buffer inside another argument buffer are not supported in the simulator'. SparkSplatRenderPipeline uses nested argument buffers (MultiCloudArgumentBuffer → SplatCloudData → GPU buffer pointers). This is a simulator Metal limitation, not fixable without restructuring the shader argument passing.
- `2026-07-22T03:05:04Z`: Fix reverted: nested-argument-buffer flattening backed out at user request; simulator rendering is broken again by design.
- `2026-07-22T03:05:30Z`: Won't fix: simulator support is not a goal. The nested-argument-buffer binding stays; splat rendering requires a real device (or macOS native).

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
status: closed
priority: low
kind: feature
labels: effort:m, demo, iOS, not-testable
created: 2026-04-09T19:19:51Z
updated: 2026-07-21T23:05:17Z
closed: 2026-07-21T23:05:17Z
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
status: closed
priority: medium
kind: bug
labels: effort:xs, macOS, demo, not-testable
created: 2026-04-09T20:07:10Z
updated: 2026-07-21T21:27:48Z
closed: 2026-07-21T21:27:48Z
+++

SplatView (via RenderView/MTKView) renders nothing when .toolbar is applied or when wrapped in NavigationStack on macOS. Resizing the window triggers rendering. Root cause is in MetalSprockets (filed as MetalSprockets#311) — MTKView gets zero initial size and never redraws. Workaround: use .overlay for UI controls instead of .toolbar.

---

## 46: Add tile-based renderer to SplatRenderer enum

+++
status: closed
priority: low
kind: enhancement
labels: effort:m, tile-based
created: 2026-04-09T20:08:11Z
updated: 2026-07-21T20:43:22Z
closed: 2026-07-21T20:43:22Z
+++

SplatRenderer currently has .spark and .stochastic but not .tileBased. TileBasedSplatPipeline requires TileSplatResources to be created and managed, so it's not a trivial drop-in. SplatView would need to lazily create and hold TileSplatResources when tile-based mode is selected.

- `2026-07-21T20:43:22Z`: Already implemented: SplatRenderer has .tileBased and SplatView renders it via TileBasedSplatPass (which manages TileSplatResources internally). Obsolete.

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
status: open
priority: low
kind: bug
labels: effort:xs, macOS, punted
created: 2026-04-09T20:13:18Z
updated: 2026-07-21T22:48:16Z
+++

The Metal GPU performance overlay disappears while dragging/panning the camera. Reappears when gesture ends. Same issue as MetalSprockets#34/#312. Flickering is reduced when shader validation is enabled (slower frame rate). Likely a SwiftUI overlay/z-ordering issue during gesture handling in RenderView.

- `2026-07-21T22:35:44Z`: Investigated: RenderView is defined in the upstream MetalSprockets package, not this repo, and this repo contains no HUD-related code to patch. The HUD flicker during drags is the same defect tracked upstream as MetalSprockets#34/#312 (RenderView overlay/z-ordering during gestures). Unblocker: fix in MetalSprockets' RenderView and bump the dependency here; nothing actionable in this repo until then.

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
status: closed
priority: low
kind: enhancement
labels: effort:s, stochastic
created: 2026-04-09T20:13:57Z
updated: 2026-07-21T22:35:29Z
closed: 2026-07-21T22:35:29Z
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
status: open
priority: medium
kind: feature
labels: effort:m, visionOS, demo, not-testable, punted
created: 2026-04-09T21:57:38Z
updated: 2026-07-21T22:48:16Z
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
status: closed
priority: medium
kind: feature
labels: visionOS, effort:l, not-testable
created: 2026-07-20T18:42:44Z
updated: 2026-07-21T21:59:56Z
closed: 2026-07-21T21:59:56Z
+++

GPUSortedSplatRenderPipeline and GPUSplatSortComputePass take a single projection/camera matrix and render mono only. SparkSplatRenderPipeline supports vertex amplification with per-view matrices, but the GPU sort path has no way to express stereo: the cull uses one projection matrix, so splats visible to only one eye could be culled incorrectly, and the pipeline exposes no multi-matrix initializer. visionOS immersive rendering therefore cannot use the GPU sort path.

---

## 57: SplatImmersiveContent should be able to use the GPU sort pipeline

+++
status: closed
priority: low
kind: enhancement
labels: visionOS, effort:m, not-testable
depends: 56
created: 2026-07-20T18:42:44Z
updated: 2026-07-21T23:02:59Z
closed: 2026-07-21T23:02:59Z
+++

SplatImmersiveContent drives immersive visionOS rendering via the CPU AsyncSortManager path. Once stereo support exists in the GPU-sorted pipeline, immersive content should be able to opt into GPU sorting/culling, removing CPU sort latency in head-tracked rendering where stale sort order is most visible.

- `2026-07-21T23:02:59Z`: Already implemented by the stereo GPU sort work (#56): SplatImmersiveContent(renderer: .gpu) encodes SplatImmersiveGPUSortElement before the render pass and renders both eyes from the GPU-sorted indices via an amplified indirect draw. Verified visionOS build.

---

## 58: Tile-based renderer performance is poor

+++
status: closed
priority: medium
kind: bug
labels: tile-based, effort:l
created: 2026-07-20T18:53:32Z
updated: 2026-07-21T21:48:53Z
closed: 2026-07-21T21:48:53Z
+++

The tile-based renderer runs significantly slower than the Spark and GPU-sorted renderers on the same scenes (observed in the demo app on macOS). Frame times are noticeably worse when switching the Renderer picker to Tile.

- `2026-07-21T21:48:53Z`: Precomputed per-splat 2D projection data (screen center, conic/inverse covariance, linear color, AA'd base alpha) once per frame in the binning write kernel; the per-pixel render loop is now a cheap conic evaluation instead of redoing covariance projection + eigendecomposition per splat per pixel. Bench (synthetic, 1024px): 4M splats 436ms -> 125ms, 8M 890ms -> 260ms (~3.5x). Remaining known cost at smaller counts is the serial per-tile radix sort and single-threaded prefix sum. Smoke test added (TileRenderingTests).

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
status: closed
priority: low
kind: enhancement
labels: tile-based, effort:m
created: 2026-07-20T18:53:32Z
updated: 2026-07-21T23:01:46Z
closed: 2026-07-21T23:01:46Z
+++

The GPU-sorted pipeline has a proper stable two-pass 8-bit radix sort over the half depth key (SplatGPUSort). The tile-based renderer uses its own per-tile sort (TileSplatSort). Investigate whether the per-tile depth ordering is currently incorrect or unstable (a possible contributor to the washed-out blending) and whether the SplatGPUSort radix approach could replace or feed the per-tile sort.

\- `2026-07-20T18:58:32Z`: Findings from code review (2026-07-20):

tile_sort (TileSplatSort.metal) is one thread per tile running a serial 4-pass 8-bit radix: 8 full walks of the tile's list (histogram + scatter x 4 passes) with a 256-entry thread-private histogram. Dense tiles serialize on a single thread — likely the bulk of the poor performance in #58. A 32-bit key is also overkill for depth ordering.

Preferred direction (classic 3DGS pipeline, as in the original CUDA implementation): drop the per-tile sort pass entirely and globally sort the binned tile entries (splat-tile pairs) with a combined key (tileID << 16) | flippedHalfDepth, using the cooperative SplatGPUSort radix already in the codebase (4 x 8-bit passes for the 32-bit key). Entries come out grouped by tile (contiguous, matching existing tileOffsets ranges) and depth-ordered within each tile. Per-tile imageblock rendering is unchanged — the range just arrives pre-sorted.

Note: this is a sort of the binned entries, not the splats — a splat overlapping N tiles appears N times with different tileID keys.

May also be relevant to #59: guarantees a stable, correct front-to-back order per tile (the current kernel sorts descending via key inversion; worth verifying direction against the renderer's expectation).

Related: #58, #59.

\- `2026-07-21T23:01:46Z`: Investigation complete (2026-07-21):

Correctness: per-tile ordering is correct and stable. Camera-space z is negative in front of the camera, so closer = larger value; tile_sort's descending sort (inverted key) therefore yields front-to-back order, matching TileSplatRender's front-to-back accumulation. The LSB-first counting radix is stable. Verified with a new GPU regression test (TileSplatSortTests: ordering across multiple tiles + stability for equal depths). The washed-out blending is NOT caused by sort order/instability.

Also fixed a misleading comment in TileSplatBinning.metal that claimed 'closer = more negative' (it's the opposite).

Performance: the one-thread-per-tile serial radix remains the known bottleneck. The preferred replacement — global SplatGPUSort radix over binned (tileID << 16 | flippedHalfDepth) keys, dropping the per-tile sort pass — is a performance rework and is tracked under #58.

---

## 62: Unified splat pipeline: shared cull + global sort front-end feeding tile-based rendering

+++
status: open
priority: low
kind: feature
labels: tile-based, effort:xl
created: 2026-07-20T19:01:34Z
updated: 2026-07-21T22:29:46Z
+++

The GPU-sorted pipeline (SplatGPUSort) and the tile-based renderer are converging on the same front-end tools: frustum cull, depth keys, radix sort. They differ only in back-end — sorted instanced quads with hardware blending (Spark/GPU) vs per-pixel front-to-back imageblock accumulation with early termination (tile).

In practice overdraw is extreme in typical splat scenes, so the Spark/GPU path pays heavily in blend bandwidth. The tile back-end is the structural cure (early termination kills overdraw per pixel), but today it loses everywhere because of its serial per-tile sort (#61) and blending bugs (#59), with overall poor performance (#58).

Target architecture: one shared front-end — cull (from SplatGPUSort), bin, global radix sort of tile entries keyed (tileID, depth) — feeding the per-tile imageblock renderer. The existing quad back-end remains as a consumer of the same cull + depth-sort passes.

Related: #58 (tile perf), #59 (tile blending), #61 (global tile|depth sort replacing per-tile sort).

- `2026-07-20T19:45:10Z`: RFC 0002 (RFCs/0002-tilealt-cull-globalsort-bin-render.md) proposes TileAlt: cull -> global depth sort -> ordered (atomics-free) bin -> stable tileID partition -> tile render, as a sibling of the existing tile renderer. Depends on MetalSprockets#351 (indirect compute dispatch).
- `2026-07-22T00:10:49Z`: RFC 0002 updated: the indirect-dispatch blocker is gone (ComputeDispatch(indirectBuffer:) available and in use since #90).

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
status: closed
priority: low
kind: none
labels: performance, pointsplat
created: 2026-07-21T14:52:10Z
updated: 2026-07-21T20:23:36Z
closed: 2026-07-21T20:23:36Z
+++

The splat kernel has an early depth test (plain aliased read) before atomic_min, but no simdgroup-level dedupe of points targeting the same pixel (Schuetz 2021 reports large wins from warp dedupe under contention). Unknown whether it pays off on Apple GPUs; needs measurement with GPU capture on close-up views.

- `2026-07-21T20:23:36Z`: Measured: replacing atomic_min with a racy plain store (same workload, wrong image) changes nothing - 4M: 15.12 vs 14.97 ms, 8M: 19.40 vs 19.50 ms (within run noise). The splat stage is not atomic-bound on Apple GPUs; the early depth test already absorbs contention. Simdgroup dedupe would add ALU cost for zero atomic savings. Not worth implementing.

---

## 66: PointSplat: profile occupancy, atomic throughput, and scaling vs sorted pipelines

+++
status: closed
priority: medium
kind: task
labels: performance, pointsplat, effort:m
created: 2026-07-21T14:52:10Z
updated: 2026-07-21T21:37:44Z
closed: 2026-07-21T21:37:44Z
+++

RFC 0003 verification plan items not yet done: GPU capture to confirm even occupancy across the splat dispatch (the paper's central claim) and atomic throughput; record the frame-time scaling curve vs Spark/GPU/Stochastic on small and multi-million-splat scenes.

- `2026-07-21T19:49:48Z`: Scaling curve done via new 'bench' CLI subcommand (synthetic seeded clouds, no fixtures; Release, 1024x1024, 20 frames, median ms): 100k: point 1.4 / spark 2.9 / gpu 2.9. 1M: 10.7 / 14.2 / 6.7. 4M: 14.7 / 53.0 / 20.5. 8M: 18.2 / 115.7 / 39.8. PointSplat flattens as predicted (bounded by points/pixel); spark is CPU-sort-bound (linear); gpu-sort wins the ~1M middle. Remaining: GPU capture for splat-dispatch occupancy and atomic throughput.
- `2026-07-21T20:23:36Z`: Atomic-throughput half answered via the #65 measurement: atomics cost ~nothing (see #65). The flat scaling curve plus this strongly supports the paper's even-workload claim; a formal occupancy capture remains optional.
- `2026-07-21T21:37:38Z`: Occupancy capture done (M5 Max, macOS 27, gpucapture + gpudebug profile run; 1M synthetic splats, 1024x1024, point renderer). Findings: pointSplatSplat executes as a single contiguous 2.78 ms interval with no straggler tail (interval timeline: one 2µs warmup blip then 11.18-13.96 ms solid), confirming even workload distribution across the dispatch. Kernel occupancy during the splat dispatch ramps to a steady 69.7% and holds flat for the entire back half; per-invocation cost is uniform (31.3M invocations, 0.15% ALU inefficiency, 1 device atomic + 8 device loads per invocation, no spills, 30 temp regs). Cost ranking: splat kernel 30.5% of frame; the workload-distributor scan (workloadScanBlockSums) dominates at 46.6% in this capture — worth a separate look but unrelated to the paper's splat-dispatch claim. Combined with the #65 atomic result (~zero cost) and the flat scaling curve, all RFC 0003 verification items are now done.

---

## 67: PointSplat: near/far planes hardcoded in interactive pipeline

+++
status: closed
priority: medium
kind: none
labels: pointsplat
created: 2026-07-21T14:52:10Z
updated: 2026-07-21T20:36:39Z
closed: 2026-07-21T20:36:39Z
+++

PointSplatRenderPipeline hardcodes nearPlane 0.2 / farPlane 200 for the 28-bit fixed-point depth quantization, ignoring the projection's zClip range. Scenes larger than 200 units or with tighter near planes will quantize depth badly. RFC 0003 open question 2 (reversed-infinite-Z reconciliation) is also unresolved.

- `2026-07-21T20:36:39Z`: PointSplatRenderPipeline takes depthRange: ClosedRange<Float>; SplatView derives it from the projection's depthMode (standard zClip directly; reversed-infinite-Z gets a finite far for quantization only). RFC 0003 open question 2 marked resolved.

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
status: closed
priority: medium
kind: task
labels: pointsplat, code-style, effort:m
created: 2026-07-21T17:47:37Z
updated: 2026-07-21T21:40:10Z
closed: 2026-07-21T21:40:10Z
+++

Offscreen and live rendering have largely parallel/duplicated code paths. Needs a dramatic cleanup to consolidate the shared logic.

---

## 71: SOGReaderCPU: ImageIO rejects some lossless WebP textures

+++
status: closed
priority: medium
kind: bug
labels: splats, effort:m
created: 2026-07-21T18:07:20Z
updated: 2026-07-21T21:42:33Z
closed: 2026-07-21T21:42:33Z
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

## 74: PointSplat: toggle to disable temporal accumulation/reprojection

+++
status: closed
priority: low
kind: feature
labels: pointsplat
created: 2026-07-21T19:45:06Z
updated: 2026-07-21T20:14:13Z
closed: 2026-07-21T20:14:13Z
+++

There is no way to view raw single-frame PointSplat output. Temporal accumulation (static views) and reprojection (camera motion) are always on, which hides per-frame noise characteristics -- useful for debugging (e.g. the current occlusion-culling render issues), for judging SPP quality honestly, and for A/B against StochasticSplats-style output. Wants a runtime toggle (demo UI + PointSplatRenderPipeline parameter) that bypasses the blend/reproject stage and presents the resolve texture directly.

- `2026-07-21T20:14:13Z`: Reproject toggle added: PointSplatRenderPipeline gains reprojection: Bool (default true) and the demo overlay a switch. Off restores pre-#73 behavior (camera motion hard-resets accumulation, showing raw noise during motion); static accumulation always runs.

---

## 75: PointSplat: group-level hierarchical culling

+++
status: closed
priority: medium
kind: enhancement
labels: pointsplat, performance, effort:l
created: 2026-07-21T20:18:36Z
updated: 2026-07-21T21:57:34Z
closed: 2026-07-21T21:57:34Z
+++

Per-Gaussian preprocess is O(total splats) every frame even when most of the cloud is frustum- or occlusion-culled: 8M threads run projection just to write count 0. The paper (Sec 3.5) adds a coarse tier: ~1M groups of consecutive Gaussians (Morton or BVH order) with precomputed 3D AABBs, culled first so per-Gaussian work only runs for surviving groups. Prerequisite for 100M-class scenes; needs splat reordering at load time to make groups spatially coherent.

---

## 76: PointSplat: sweep K and supersampling settings on Apple GPUs

+++
status: closed
priority: low
kind: task
labels: pointsplat, performance, effort:s
created: 2026-07-21T20:18:36Z
updated: 2026-07-21T23:03:48Z
closed: 2026-07-21T23:03:48Z
+++

We use the paper's defaults (2x2 supersampling, K=4) untested on our hardware. The paper measured K=1 vs K=4 as +37% frame time on NVIDIA; K=8/16, 1x1+accumulation, and 4x4 are unswept here. The bench subcommand makes this a quick experiment: quality (PSNR vs converged) and frame time per configuration, pick per-platform defaults.

- `2026-07-21T20:33:04Z`: Timing sweep done via bench --supersampling/--points-per-thread (1M/8M synthetic, Release, median ms): S1K1 9.6/17.0, S1K4 3.5/10.4, S2K1 40.7/50.9, S2K4 (default) 10.7/19.4, S2K8 6.5/15.3, S2K16 4.6/12.9, S4K4 42.2/72.8, S4K16 20.3/51.3. K dominates: S2K16 is 2.3x faster than the default. Caveat: counts round stochastically to multiples of K, so large K adds per-frame variance on small splats. Demo overlay now has live S and K pickers for the visual half; defaults unchanged pending that judgment.
- `2026-07-21T23:03:48Z`: Quality half done via new 'bench --point-quality' PSNR sweep (single-frame PSNR vs 512-frame converged S2K4 reference, 1M and 8M synthetic, 512px): K has no measurable PSNR cost (S2K1=34.98, S2K4=34.97, S2K8=34.99, S2K16=35.00 dB at 1M; same story at 8M), while S dominates quality (~+6 dB per doubling: S1~29, S2~35, S4~41 dB). Combined with the timing sweep (S2K16 2.3x faster than S2K4), picked S=2, K=16 as the Apple-GPU default: PointSplatRenderPipeline default pointsPerThread 4 -> 16, demo overlay default likewise. Supersampling default stays 2 (S4 doubles quality but is 3-4x slower).

---

## 77: PointSplat: quantized splat storage

+++
status: closed
priority: low
kind: enhancement
labels: pointsplat, splats, memory, effort:l
created: 2026-07-21T20:18:36Z
updated: 2026-07-21T23:12:18Z
closed: 2026-07-21T23:12:18Z
+++

SparkSplat is 32 bytes plus float32 SH coefficients; the paper packs a Gaussian into 21 bytes (fixed-point means, 10-bit log scales, 30-bit quaternion, 8-bit opacity) with 8-bit palette-quantized SH, roughly 4x smaller. Splat-stage read bandwidth and total memory scale accordingly; matters for multi-10M clouds (48M splats = 1.5 GB today before SH). Touches every renderer that consumes SparkSplat, so likely a parallel packed format consumed by PointSplat first.

- `2026-07-21T23:12:18Z`: Implemented the parallel packed format, PointSplat-first as suggested: GPSPackedSplat is 18 bytes vs SparkSplat's 32 (16-bit fixed-point means in the cloud AABB, 3x10-bit log scales, smallest-three 30-bit quaternion, 8-bit rgba). PackedSplatCloud packs on CPU and the PointSplat kernels decode on load behind a uniforms flag (unpacked path unchanged); PointSplatRenderer gained render(packed:), and bench gained --packed. Tests: CPU round-trip accuracy, zero-scale handling, and a GPU packed-vs-unpacked converged PSNR check (>30 dB). Timing at 8M synthetic is neutral-to-slightly-faster (17.6 -> 17.3 ms median); the win is the 44% storage cut. Not done: 8-bit palette-quantized SH (this offscreen path is color-only) and adoption by the other SparkSplat renderers.

---

## 78: PointSplat indirect dispatches bypass the new ComputeDispatch(indirectBuffer:) element

+++
status: closed
priority: low
kind: enhancement
labels: pointsplat, effort:m, punted
created: 2026-07-21T20:37:59Z
updated: 2026-07-21T23:28:05Z
closed: 2026-07-21T23:28:05Z
+++

MetalSprockets 92dbfa0 added declarative indirect dispatch (ComputeDispatch(indirectBuffer:threadsPerThreadgroup:), MetalSprockets#351), but all three indirect dispatch sites here still call encoder.dispatchThreadgroups(indirectBuffer:) on raw encoders: PointSplatWorkloadDistributor.encode, PointSplatResources.encodePhase, and PointSplatRenderer. The surrounding PointSplat frame is raw-encoded for more than just the old dispatch gap (mid-frame distributor re-runs, two-phase occlusion), so adopting the element means refactoring that flow back into declarative elements, not a drop-in swap. Related: #62 (TileAlt, was blocked on MetalSprockets#351), #63 (where the raw workaround landed).

- `2026-07-21T22:41:36Z`: Looked at adopting ComputeDispatch(indirectBuffer:) here. Confirmed the element exists (MetalSprockets 92dbfa0) and works for standalone dispatches, but all three indirect sites live inside the raw-encoded frame flow: PointSplatResources.encodeFrame/encodePhase sequences ~10 pipeline states (clear, group bounds/cull, indirect preprocess, distributor, indirect splat, pyramid build) on one raw encoder, re-running the distributor mid-frame for the two-phase occlusion pass, and PointSplatRenderer drives the same code offscreen with no element System at all. Adopting the element means rewriting that entire flow as declarative ComputePipeline/ComputeDispatch elements (including converting the MTLComputePipelineState-based kernels to ComputeKernel + .parameter bindings) and giving the offscreen renderer an element host. That is a substantial refactor, not a batch-sized change. Unblocker: split this into (1) convert encodePhase to element-built ComputePipelines inside the live pipeline body, (2) port the offscreen PointSplatRenderer to run the same element tree, then the indirect dispatches fall out naturally.
- `2026-07-21T23:28:05Z`: Superseded by #90: element adoption requires rewriting the raw-encoded frame flow first.

---

## 79: SparkSplatRenderPipeline: cloudDataBuffer allocated on every body evaluation

+++
status: closed
priority: medium
kind: bug
labels: spark, performance, code-style, effort:s
created: 2026-07-21T20:28:32Z
updated: 2026-07-21T21:09:07Z
closed: 2026-07-21T21:09:07Z
+++

`renderPipeline(sortedIndices:)` (called from `body`) allocates a fresh `cloudDataBuffer` via `device.makeTypedBuffer(values:...)` each time it runs. MetalSprockets element `body` must stay pure and can be evaluated multiple times per frame, so this is an allocation side effect in body: a new MTLBuffer per evaluation, per frame. Expected: buffer allocated once (or on cloud change) and reused; actual: per-evaluation allocation churn.

- `2026-07-21T21:09:07Z`: cloudDataBuffer now cached in @MSState keyed on (modelMatrix, clouds) - reference equality on clouds, so the check is cheap. A changed key allocates a new buffer rather than mutating the old, so in-flight frames keep valid data. Also synced the demo's Package.resolved to the same MetalSprockets revision as the package build (mixed pins made _MTLCreateSystemDefaultDevice ambiguous).

---

## 80: GPUSortedSplatRenderPipeline: slot advance is a side effect in body

+++
status: closed
priority: medium
kind: bug
labels: spark, gpu-sort, code-style, effort:s
created: 2026-07-21T20:28:39Z
updated: 2026-07-21T21:12:15Z
closed: 2026-07-21T21:12:15Z
+++

`GPUSortedSplatRenderPipeline.body` calls `resources.advance()` and `resources.makeIndices(...)`, which mutate the shared `GPUSortResources` slot state. MetalSprockets `body` can be evaluated multiple times per frame (diffing, re-expansion), so the slot index can advance more than once per rendered frame, breaking the frames-in-flight slot rotation the type documents (slotCount default 3). Side effects belong in lifecycle hooks, not body.

- `2026-07-21T21:12:15Z`: Slot advance and indices creation moved from body to init: the element value is constructed once per frame while body can re-evaluate, so the frames-in-flight rotation now ticks exactly once per constructed pipeline.

---

## 81: StochasticSplatRenderPipeline: uniforms and textures bound via raw encoder calls instead of .parameter

+++
status: closed
priority: low
kind: task
labels: stochastic, code-style, effort:s
created: 2026-07-21T20:28:39Z
updated: 2026-07-21T22:34:34Z
closed: 2026-07-21T22:34:34Z
+++

The Draw closure in StochasticSplatRenderPipeline binds `time`, `alphaThreshold`, the blue-noise texture, the SH degree, and the SH buffer with raw `setFragmentBytes`/`setFragmentTexture`/`setVertexBytes`/`setVertexBuffer` at hard-coded indices, while the rest of the pipeline uses reflection-based `.parameter(...)`. These are all small uniforms/textures that `.parameter` handles; no justification is given for bypassing it. Also uses `MemoryLayout<...>.size` rather than `.stride`.

---

## 82: PointSplatRenderPipeline: accumulation step advances ping-pong state inside body

+++
status: closed
priority: medium
kind: bug
labels: pointsplat, code-style, effort:s
created: 2026-07-21T20:28:46Z
updated: 2026-07-21T21:32:07Z
closed: 2026-07-21T21:32:07Z
+++

`PointSplatRenderPipeline.body` calls `resources.nextAccumulationStep(...)`, which mutates `frameParity`, `accumulatedFrames`, and the last-matrix tracking. `body` can be evaluated multiple times per frame, so the ping-pong parity and accumulation count can advance more than once per rendered frame, corrupting the running mean. Unlike `validatedResources()` (which has a comment explaining its eager mutation), this side effect is unacknowledged.

- `2026-07-21T21:32:07Z`: nextAccumulationStep is now idempotent per frameIndex: repeat body evaluations for the same frame return the cached step instead of advancing ping-pong parity and accumulation count. Regression test added.

---

## 83: PointSplatResources creates its own MTLDevice instead of using the environment device

+++
status: closed
priority: low
kind: task
labels: pointsplat, code-style, effort:s
created: 2026-07-21T20:28:46Z
updated: 2026-07-21T22:37:31Z
closed: 2026-07-21T22:37:31Z
+++

`PointSplatResources.init` calls `MTLCreateSystemDefaultDevice()` directly rather than using the device MetalSprockets publishes via `@MSEnvironment(\.device)` (e.g. allocation in `.onSetupEnter`). This diverges from framework convention, and on multi-GPU systems the resources could be allocated on a different device than the one the render view uses.

---

## 84: TileSplatRenderPass and SparkSplatDebugRenderPipeline bind buffers/uniforms via raw encoder calls instead of .parameter

+++
status: closed
priority: low
kind: task
labels: tile-based, spark, code-style, effort:s
created: 2026-07-21T20:28:54Z
updated: 2026-07-21T22:36:48Z
closed: 2026-07-21T22:36:48Z
+++

TileSplatRenderPass's first Draw closure binds the splat buffer, tile indices, tile offsets, and uniforms with raw `setFragmentBuffer`/`setFragmentBytes` at hard-coded indices instead of reflection-based `.parameter(...)`. SparkSplatDebugRenderPipeline similarly binds its per-mode debug params and boundingBox with raw `setFragmentBytes`/`setVertexBytes`. No justification is given for bypassing bind-by-name in either. Both also use `MemoryLayout<...>.size` rather than `.stride`.

---

## 85: Shader recreation in .onChange hooks uses try!/fatalError on failure

+++
status: closed
priority: low
kind: task
labels: spark, tile-based, code-style, effort:s
created: 2026-07-21T20:28:54Z
updated: 2026-07-21T22:39:16Z
closed: 2026-07-21T22:39:16Z
+++

Three renderers recreate function-constant-specialized shaders inside `.onChange` hooks and crash on failure instead of surfacing the error:

- SparkSplatRenderPipeline: `do/catch` with `fatalError("Failed to recreate shaders: ...")`
- TileSplatRenderPass: `try! Self.makeFragmentShader(...)`
- TileHeatMapRenderPass: `try! Self.makeFragmentShader(...)`

A shader-compilation failure at runtime (e.g. bad function constant) takes down the process rather than failing the frame or propagating through MetalSprockets' throwing element machinery.

---

## 86: SparkSplatRenderPipeline: boundingBox and shDegree bound via raw setVertexBytes instead of .parameter

+++
status: closed
priority: low
kind: task
labels: spark, code-style, effort:s
created: 2026-07-21T20:28:32Z
updated: 2026-07-21T22:40:04Z
closed: 2026-07-21T22:40:04Z
+++

In SparkSplatRenderPipeline's Draw closure, `shDegreeValue` (index 11) and `boundingBox` (index 12) are bound with raw `commandEncoder.setVertexBytes` instead of MetalSprockets' reflection-based `.parameter(...)`. The shDegree binding has a comment explaining why it must always be bound, but the boundingBox binding has no justification. Raw index-based binding loses bind-by-name reflection and diverges from the framework convention used for the other uniforms in the same pipeline. Also uses `MemoryLayout<...>.size` rather than `.stride`.

---

## 87: Support .lcc2 splat format

+++
status: closed
priority: medium
kind: feature
labels: splats, effort:l, punted
created: 2026-07-21T21:44:25Z
updated: 2026-07-21T22:58:34Z
closed: 2026-07-21T22:58:34Z
+++

The LCC2 format (from XGRIDS) is a Gaussian splat container format that is not currently supported for loading/rendering.

Whitepaper/spec: https://github.com/xgrids/LCC2Whitepaper

- `2026-07-21T22:58:34Z`: Closing: LCC2 is a container format wrapping compressed splat payloads; not planning a reader for it right now.

---

## 88: Audit code comments against writing-comments skill

+++
status: closed
priority: medium
kind: task
labels: code-style, effort:m
created: 2026-07-21T21:54:29Z
updated: 2026-07-21T23:20:28Z
closed: 2026-07-21T23:20:28Z
+++

Source comments across the project have not been audited against the house writing-comments skill rules. Review comments in Sources/, Examples/, and Tests/ for violations (redundant narration, stale/incorrect comments, commented-out code, etc.) and clean them up.

---

## 89: PointSplat: Morton-reorder splats at load time for group culling coherence

+++
status: closed
priority: medium
kind: enhancement
labels: pointsplat, performance, effort:m
created: 2026-07-21T21:57:34Z
updated: 2026-07-21T22:41:13Z
closed: 2026-07-21T22:41:13Z
+++

Group-level hierarchical culling (#75) uses groups of 256 consecutive Gaussians with precomputed AABBs. Culling effectiveness depends on groups being spatially coherent; PLY/SOG files are often only loosely ordered. Add an optional Morton (or BVH) reorder of the splat array at load time so group AABBs are tight and whole groups cull cleanly. Remember to reorder SH coefficient storage alongside positions.

---

## 90: PointSplat: rewrite raw-encoded frame flow as MetalSprockets elements

+++
status: closed
priority: low
kind: enhancement
labels: pointsplat, effort:l
created: 2026-07-21T23:28:02Z
updated: 2026-07-21T23:36:31Z
closed: 2026-07-21T23:36:31Z
+++

PointSplatResources.encodeFrame/encodePhase sequences ~10 pipeline states on one raw compute encoder (clear, group bounds/cull, indirect preprocess, distributor, indirect splat, pyramid build), re-running the distributor mid-frame for the two-phase occlusion pass. PointSplatRenderer drives the same code offscreen with no element System. Because of this, the indirect dispatches cannot use ComputeDispatch(indirectBuffer:) (formerly #78).

Two stages: (1) convert encodePhase to element-built ComputePipelines (ComputeKernel + .parameter bindings) inside the live pipeline body; (2) port the offscreen PointSplatRenderer to run the same element tree. The indirect-dispatch element adoption then falls out naturally.

---

## 91: SOGReaderGPU: decode dispatch uses raw encoder instead of MetalSprockets elements

+++
status: closed
priority: low
kind: enhancement
labels: splats, code-style, effort:s
created: 2026-07-21T23:43:53Z
updated: 2026-07-21T23:46:28Z
closed: 2026-07-21T23:46:28Z
+++

SOGReaderGPU.load builds a raw command queue/encoder and binds 6 buffers and 7 textures by index for the one-shot SOG decode compute dispatch. The Splats target already depends on MetalSprockets, so this could run a ComputePipeline/ComputeDispatch element tree through a Runner with .parameter name bindings, like PointSplatWorkloadDistributor.build().

---

## 92: BenchCommand: texture readback uses a raw blit encoder

+++
status: closed
priority: low
kind: task
labels: code-style, effort:xs
created: 2026-07-21T23:43:53Z
updated: 2026-07-21T23:46:34Z
closed: 2026-07-21T23:46:34Z
+++

BenchCommand creates its own command queue and a raw MTLBlitCommandEncoder to synchronize a texture for CPU readback. Could use a BlitPass element (or a Runner-driven tree) instead of raw encoding.

---

## 93: GPUSplatCloud: unsynchronized mutable state under @unchecked Sendable

+++
status: closed
priority: medium
kind: bug
labels: concurrency, splats, effort:s
created: 2026-07-21T23:48:54Z
updated: 2026-07-21T23:55:14Z
closed: 2026-07-21T23:55:14Z
+++

GPUSplatCloud is @unchecked Sendable but modelTransform and opacity are plain vars with no synchronization. The cloud is shared between the main thread (UI mutates transform/opacity) and the AsyncSortManager actor (reads during sorts); simd_float4x4 is 64 bytes so a torn read mid-sort is possible.

---

## 94: managedSortedIndicesStream: unbounded buffering can yield already-released buffers

+++
status: closed
priority: medium
kind: bug
labels: concurrency, sorting, effort:s
created: 2026-07-21T23:48:54Z
updated: 2026-07-21T23:55:48Z
closed: 2026-07-21T23:55:48Z
+++

AsyncSortManager.managedSortedIndicesStream uses the closure AsyncStream initializer with the default .unbounded buffering policy. The producer task releases superseded indices once they fall out of the pendingReleaseDepth window, but yielded values sit in the stream buffer until consumed - a consumer lagging more than depth values can dequeue SplatIndices whose buffers were already returned to the pool. Also uses the closure initializer instead of AsyncStream.makeStream(of:).

---

## 95: ARSplatView: per-frame unstructured tasks can deliver ARKit frames out of order

+++
status: closed
priority: low
kind: bug
labels: concurrency, demo, iOS, effort:xs
created: 2026-07-21T23:49:07Z
updated: 2026-07-21T23:55:05Z
closed: 2026-07-21T23:55:05Z
+++

ARSplatSessionModel.session(_:didUpdate:) spawns an unstructured Task { @MainActor in currentFrame = frame } per ARKit frame (60 Hz). Task start order is not FIFO, so currentFrame can go backwards under load, and task creation is unbounded. A latest-value AsyncStream (bufferingNewest(1)) with a single consumer preserves order.

---

## 96: PointSplatStatistics: @unchecked Sendable without synchronization

+++
status: closed
priority: low
kind: task
labels: concurrency, pointsplat, code-style, effort:xs
created: 2026-07-21T23:49:07Z
updated: 2026-07-21T23:55:56Z
closed: 2026-07-21T23:55:56Z
+++

PointSplatStatistics is @unchecked Sendable but its three fields have no synchronization. Both writer (element workload phase) and reader (SwiftUI polling) are currently the main thread, so it works, but the conformance advertises cross-thread safety it does not have. Either drop the conformance and mark it @MainActor, or guard the fields with OSAllocatedUnfairLock.

---

## 97: DemoState.loadCustomSplat: replace Task.detached with @concurrent function

+++
status: closed
priority: low
kind: enhancement
labels: concurrency, demo, effort:xs
created: 2026-07-21T23:49:08Z
updated: 2026-07-21T23:56:49Z
closed: 2026-07-21T23:56:49Z
+++

loadCustomSplat offloads parsing via Task.detached(priority: .userInitiated), which sheds priority escalation and task-local context. Swift 6.2 preference is a nonisolated @concurrent async function so the call stays structured. Also add a doc-comment constraint to AsyncSortManager.sortNowSync noting it must not be called from an async context (spin-wait would burn a cooperative-pool thread).

---

## 98: ARSplatView: heavy work and try!/force-unwrap in view init

+++
status: closed
priority: low
kind: bug
labels: demo, iOS, code-style, effort:xs
created: 2026-07-21T23:50:42Z
updated: 2026-07-21T23:55:36Z
closed: 2026-07-21T23:55:36Z
+++

ARSplatView.init calls MTLCreateSystemDefaultDevice()! and try! AsyncSortManager(...) to seed @State. View inits can run on every parent body evaluation, and sample code gets copied - crashes on failure instead of degrading, and allocates a sort manager eagerly. Move creation into a model object or .task, and handle failure without force-unwrap/try!.

---

## 99: API: demote unused-externally public types to internal

+++
status: closed
priority: medium
kind: task
labels: api, effort:s
created: 2026-07-21T23:52:19Z
updated: 2026-07-21T23:56:40Z
closed: 2026-07-21T23:56:40Z
+++

These public types have no users outside the library (not demo, CLI, or tests): TileSplatResources, TileBinningCountPass, TileBinningWritePass, TilePrefixSumComputePass, TileSortingComputePass, TileHeatMapRenderPass (tile internals; TileBasedSplatPipeline is the public entry), and AnyGPUSplatCloud (unused everywhere). Pool, SingleValueStream, and PointSplatWorkloadDistributor are used only by tests - internal + @testable candidates. Un-publishing after a version tag is breaking, so demote before the next release.

---

## 100: API: consolidate PointSplat error enums

+++
status: closed
priority: low
kind: enhancement
labels: api, pointsplat, effort:s
created: 2026-07-21T23:52:19Z
updated: 2026-07-21T23:56:49Z
closed: 2026-07-21T23:56:49Z
+++

PointSplat has three public error enums: PointSplatRenderer.RendererError, PointSplatWorkloadDistributor.DistributorError, and PackedSplatCloud.PackError. Callers cannot handle them uniformly, and PointSplatResources throwing PointSplatRenderer.RendererError shows the boundary is wrong. A single PointSplatError enum would cover the cases.

---

## 101: API: configuration structs for SparkSplatRenderPipeline and PointSplatRenderPipeline inits

+++
status: closed
priority: low
kind: enhancement
labels: api, effort:m
created: 2026-07-21T23:52:19Z
updated: 2026-07-21T23:58:39Z
closed: 2026-07-21T23:58:39Z
+++

SparkSplatRenderPipeline has three public init overloads with 9 parameters each (single/multi cloud x mono/stereo, plus convertSRGBToLinear/useSphericalHarmonics/boundingBox). PointSplatRenderPipeline.init takes 11 parameters while the offscreen PointSplatRenderer already has a Configuration struct the live pipeline does not share. Introduce configuration types with defaults to collapse the overload matrix.

---

## 102: API: reader naming is inconsistent (read vs load) and SOGReaderGPU skips SplatReaderProtocol

+++
status: closed
priority: low
kind: task
labels: api, splats, effort:s
created: 2026-07-21T23:52:19Z
updated: 2026-07-21T23:57:47Z
closed: 2026-07-21T23:57:47Z
+++

All splat readers stream via read(_ handler:) and conform to SplatReaderProtocol except SOGReaderGPU, which exposes load(url:) -> Result and does not conform. Three patterns exist for getting splats from a file: init(url:) + read, init(data:), and load(url:). Pick one naming convention; document why the GPU reader's shape differs if it must.

---

## 103: SplatImmersiveRenderState.init uses try! on a public API path

+++
status: closed
priority: low
kind: bug
labels: api, visionOS, effort:xs
created: 2026-07-21T23:52:20Z
updated: 2026-07-21T23:59:38Z
closed: 2026-07-21T23:59:38Z
+++

SplatImmersiveRenderState.init constructs its per-eye AsyncSortManagers with try!, crashing instead of throwing on failure. Public API should not force-unwrap; make the init throwing (same class of issue as #98).

---

## 104: PointSplat: angle-stratified intra-thread sampling (RFC 0005 §1)

+++
status: closed
priority: low
kind: enhancement
labels: pointsplat, performance, effort:s, impact:high
created: 2026-07-22T00:10:33Z
updated: 2026-07-22T02:39:41Z
closed: 2026-07-22T02:39:41Z
+++

RFC 0005 proposal 1, cheap intermediate: stratify u1 (the angle) across a thread's K samples of one Gaussian. Strictly reduces radial clumping with no new math; measurable variance win. The full stratified re-derivation (binomial-of-strata collision correction, points -~40%) is a separate, larger step. Verify with the RFC 0003 convergence test. Part of RFCs/0005.

---

## 105: PointSplat: importance-driven per-Gaussian budget allocation (RFC 0005 §2a)

+++
status: closed
priority: low
kind: enhancement
labels: pointsplat, performance, effort:s, impact:high
created: 2026-07-22T00:10:33Z
updated: 2026-07-22T02:41:03Z
closed: 2026-07-22T02:41:03Z
+++

RFC 0005 proposal 2a: the RFC 0004 budget-scaling pass applies a uniform T/demand scale; make it per-Gaussian, weighting by estimated visibility (depth-pyramid occlusion from #69's pyramid). Depends on the existing depth pyramid. Part of RFCs/0005.

---

## 106: PointSplat: point-size LoD under budget pressure (RFC 0005 §3)

+++
status: closed
priority: low
kind: enhancement
labels: pointsplat, performance, effort:m, impact:medium
created: 2026-07-22T00:10:33Z
updated: 2026-07-22T02:50:25Z
closed: 2026-07-22T02:50:25Z
+++

RFC 0005 proposal 3: when over budget, grow point size for small-footprint Gaussians instead of thinning uniformly, engaging only below a scale threshold (e.g. s < 0.5). Builds on RFC 0004's scaling pass. Part of RFCs/0005.

---

## 107: PointSplat: temporal point reuse, reservoir-style (RFC 0005 §4)

+++
status: open
priority: low
kind: enhancement
labels: pointsplat, performance, effort:m, impact:high, punted
created: 2026-07-22T00:10:45Z
updated: 2026-07-22T02:47:38Z
+++

RFC 0005 proposal 4: reuse surviving points across frames reservoir-style instead of resampling every frame, reducing noise and work during interactive motion. Depends on the reprojection transform (already available from #73's temporal reprojection). Part of RFCs/0005.

- `2026-07-22T02:47:38Z`: Shipped and reverted: seeding from the resolve texture chains history recursively (the resolve already contains prior seeds), so surfaces from several frames back persist during rotation - visible flashback artifacts. Seeding is now disabled (reuseFactor = 0); the kernel remains. Fix requires a non-chained seed source: either seed from a separate fresh-points-only resolve, or add seed age tracking / depth validation so stale seeds die after one frame.

---

## 108: PointSplat: exact sub-pixel splatting (RFC 0005 §5)

+++
status: closed
priority: low
kind: enhancement
labels: pointsplat, effort:m, impact:medium
created: 2026-07-22T00:10:45Z
updated: 2026-07-22T02:54:34Z
closed: 2026-07-22T02:54:34Z
+++

RFC 0005 proposal 5: for Gaussians with sub-pixel footprints, splat a single exact point (analytic coverage) instead of stochastic sampling - removes bias and reduces work at distance. Part of RFCs/0005.

---

## 109: PointSplat: full stratified sampling re-derivation (RFC 0005 §1, full)

+++
status: open
priority: low
kind: enhancement
labels: pointsplat, performance, effort:l, impact:high, punted
depends: 104
created: 2026-07-22T00:10:45Z
updated: 2026-07-22T02:45:14Z
+++

RFC 0005 proposal 1, full version: re-derive the collision correction with the Poisson model replaced by a binomial-of-strata model for K stratified per-thread samples; tabulate if no closed form. Expected ~40% fewer points for high-opacity Gaussians at equal quality. Depends on #104 landing first as the cheap baseline. Part of RFCs/0005.

- `2026-07-22T02:45:14Z`: Landed the prerequisite #104 (angle stratification). Punting the full re-derivation: replacing the Poisson collision model with a binomial-of-strata correction is open math per the RFC (may need tabulation), and a subtly wrong density would pass the PSNR test while biasing renders. Unblocker: a worked derivation (or a decision to tabulate numerically against Monte Carlo ground truth, with an agreed validation protocol beyond the existing convergence test).

---

## 110: PointSplat: convergence-weighted accumulation (RFC 0005 §2b)

+++
status: open
priority: low
kind: enhancement
labels: pointsplat, effort:m, impact:medium, punted
created: 2026-07-22T00:10:45Z
updated: 2026-07-22T02:54:55Z
+++

RFC 0005 proposal 2b: track per-region variance and weight the temporal accumulation (or budget) toward unconverged regions. Part of RFCs/0005.

- `2026-07-22T02:54:55Z`: Deferring: convergence weighting adds another temporal feedback loop (per-region variance of the accumulation buffer feeding the budget) while #112 (flashback artifacts during rotation) implicates the existing temporal machinery. Unblocker: resolve #112 first so a new history-dependent weighting isn't layered on an unresolved temporal artifact.

---

## 111: PointSplat: tighter depth/color packing (RFC 0005 §7)

+++
status: open
priority: low
kind: enhancement
labels: pointsplat, memory, effort:s, impact:low
created: 2026-07-22T00:10:45Z
updated: 2026-07-22T02:37:59Z
+++

RFC 0005 proposal 7: revisit the 64-bit framebuffer packing - the paper's 28-bit fixed-point view-space depth and 3x12-bit sRGB color over [0,16) leave headroom; small quality/precision polish. Part of RFCs/0005.

---

## 112: PointSplat: flashback/stale-frame artifacts during camera rotation

+++
status: new
priority: medium
kind: bug
labels: pointsplat, not-testable, effort:m
created: 2026-07-22T02:48:17Z
+++

Rotating the camera shows content that looks a frame or several old, as if rendering lags the camera. Reproduces with temporal point reuse disabled (reuseFactor = 0, #107 reverted), so seeding is not (or not the only) cause.

Suspects, untested:
- Color-space temporal reprojection (#73): warp + clamp of accumulated history on motion frames may retain stale surfaces (accumulatedFrames is clamped to 9, so history carries ~9 frames of weight).
- Visibility-weighted budget (#105): stale depth pyramid downweights newly-disoccluded Gaussians for a frame, delaying their appearance.
- Pre-existing: reprojection ghosting the paper itself admits to.

Repro: demo, PointSplat renderer, rotate camera. Bisect by toggling reprojection (#74 toggle) and reverting #105 to binary occlusion.

---

## 113: CLI: no performance statistics reporting on the render command

+++
status: closed
priority: low
kind: feature
labels: cli, performance
created: 2026-08-11T05:32:09Z
updated: 2026-08-11T06:45:16Z
closed: 2026-08-11T06:45:16Z
+++

The reference splat-render CLI (gaussiansplats-ios) reports render statistics via --statistics text|json: wall time, command-buffer GPU time for sort and render, a per-pass breakdown from GPU timestamp counter sampling (including vertex/fragment stage times), and visible/culled splat counts. It supports --warmup N (discarded frames to warm pipeline caches and GPU clocks) and --frames N (medians over a run), and PNG output is optional so the tool can be used for measurement alone. Our metalsprockets-gaussian-splat render command has none of this — the bench subcommand only measures wall-clock medians, with no per-pass GPU counter timings, no JSON output for tooling, and no stats for a specific render invocation.

- `2026-08-11T06:45:16Z`: Render command now supports --statistics text|json, --warmup, --frames, optional --output, and --sort cpu|gpu with per-pass GPU counter timings (vertex/fragment breakdown, GPU sort compute time, culling counts).

---

## 114: CLI: no MetalFX spatial upscaling option

+++
status: new
priority: low
kind: feature
labels: cli, performance
created: 2026-08-11T05:32:16Z
+++

splat-render (gaussiansplats-ios) offers --metalfx <factor>: it renders at a reduced resolution (factor 2 renders a quarter of the fragments) and upscales back to the requested --width/--height using MetalFX spatial upscaling, with a clear error on unsupported devices. Our CLI always renders at full resolution; there is no way to trade fragment work for upscaling quality, which also makes cross-tool performance comparisons at matching settings impossible.

---

## 115: CLI: camera cannot be specified as a full camera-to-world matrix

+++
status: closed
priority: low
kind: feature
labels: cli
created: 2026-08-11T05:32:16Z
updated: 2026-08-11T14:44:24Z
closed: 2026-08-11T14:44:24Z
+++

splat-render (gaussiansplats-ios) accepts --camera-matrix with 16 column-major values, defining the entire camera-to-world transform in one flag and overriding the eye/look-at/up flags. Our CLI only supports camera position, look-at target, and rotation as a quaternion or 3x3 matrix; there is no way to pass an exact 4x4 camera matrix, e.g. one exported from another tool or dataset, which makes reproducing a reference camera pose exactly awkward.

- `2026-08-11T14:44:24Z`: Added --camera-matrix (16 column-major camera-to-world values) and the cameraMatrix config field; takes priority over and cannot be combined with the other camera flags.

---

## 116: PointSplatRenderer cannot be timed with GPU counters

+++
status: closed
priority: medium
kind: enhancement
labels: pointsplat, performance, cli
created: 2026-08-11T06:51:36Z
updated: 2026-08-11T06:55:18Z
closed: 2026-08-11T06:55:18Z
+++

PointSplatRenderer's public API is an imperative class (render(...) -> MTLTexture) rather than a MetalSprockets Element, and the element-building internals (PointSplatResources.frameElements/resolveElements, its private Runner) are internal. Callers therefore cannot attach .gpuCounters() to its compute passes the way they can for SparkSplatRenderPipeline, TileBasedSplatPass, and StochasticSplatRenderPipeline. Concretely, the CLI's --statistics report only shows wall time for --renderer point — no GPU pass time, unlike the other renderers.

- `2026-08-11T06:55:18Z`: PointSplatRenderer gains onGPUCounterSample; the CLI wires it into --statistics so --renderer point reports GPU pass time.

---

## 117: Offscreen point splat rendering is not composable as an element

+++
status: closed
priority: medium
kind: enhancement
labels: pointsplat, cli
created: 2026-08-11T06:54:29Z
updated: 2026-08-11T06:58:28Z
closed: 2026-08-11T06:58:28Z
+++

PointSplatRenderer is an imperative class: render(...) blocks on its own private Runner and returns an MTLTexture. Unlike SparkSplatRenderPipeline, TileBasedSplatPass, and StochasticSplatRenderPipeline, there is no way to place offscreen point splat rendering inside an element tree (OffscreenRenderer.render, RenderView, or alongside other passes in one submission), attach modifiers (.gpuCounters beyond the ad-hoc onGPUCounterSample hook added for #116), or combine it with other passes in a single command buffer. The live PointSplatRenderPipeline element shares the same PointSplatResources, so the building blocks exist but are not exposed for offscreen composition.

- `2026-08-11T06:58:28Z`: Added PointSplatComputePass, a composable element for offscreen point splat frames; PointSplatRenderer is now a thin blocking wrapper around it.

---

## 118: No unified offscreen rendering API; CLI carries renderer-specific logic

+++
status: closed
priority: medium
kind: enhancement
labels: cli, architecture
created: 2026-08-11T06:59:15Z
updated: 2026-08-11T07:07:33Z
closed: 2026-08-11T07:07:33Z
+++

Each splat renderer has a different offscreen shape, so every caller must know per-renderer details: SparkSplatRenderPipeline is an element that must be placed inside a RenderPass and fed sortedIndices from a separately-run CPU or GPU sort (attaching counters to the GPU-sort path means hand-mirroring GPUSortedSplatRenderPipeline's body); TileBasedSplatPass and StochasticSplatRenderPipeline are self-contained elements with differing requirements (stochastic needs depthCompare and a per-frame seed); PointSplatComputePass is compute-only, writes an rgba32Float texture instead of the render target, and callers must convert that to an image themselves since MTLTexture.toCGImage() only handles bgra8.

Concretely, the CLI's performRender has a per-renderer frame function for each pipeline, a separate non-OffscreenRenderer path for point, and its own float->sRGB PNG conversion — logic that any other offscreen consumer (tests, thumbnailers, bench) would have to duplicate. The library has no single 'render one offscreen frame of cloud X with renderer Y (with optional GPU counters)' entry point that hides sorting, pass shape, and output-format differences.

- `2026-08-11T07:07:33Z`: Added OffscreenSplatRenderer: a unified offscreen API over spark (cpu/gpu sort), tile, stochastic, and point, with per-frame GPU counter reports and image conversion. CLI performRender is now a thin driver.

---

## 119: PointSplatRenderer class is redundant now that PointSplatComputePass exists

+++
status: closed
priority: medium
kind: task
labels: pointsplat, architecture
created: 2026-08-11T07:11:33Z
updated: 2026-08-11T07:17:01Z
closed: 2026-08-11T07:17:01Z
+++

The element is the main unit of composition; PointSplatRenderer survives only as a thin blocking convenience (private Runner + rgba32Float out texture) around PointSplatComputePass, duplicating what OffscreenSplatRenderer's point path already does. Its remaining users are the bench command (benchmarkPointSplat, pointQualitySweep) and the PointSplat test suites (PointSplatRendererTests, PointSplatConvergenceTests, PackedSplatCloudTests), all of which could drive PointSplatComputePass (or OffscreenSplatRenderer) directly. Keeping the class means two public offscreen entry points for the same compute work.

- `2026-08-11T07:17:01Z`: PointSplatRenderer deleted; PointSplatComputePass is the offscreen unit. Tests and bench drive the element via small local blocking wrappers.

---

## 120: spark-screenshot: flaky 'Timeout waiting for splat to initialize' failures; exits 0 on failure

+++
status: closed
priority: medium
kind: bug
labels: tools
created: 2026-08-11T16:23:41Z
updated: 2026-08-11T16:47:53Z
closed: 2026-08-11T16:47:53Z
+++

Tools/spark-screenshot advertises .splat support (--splat help text: .splat, .ply, .spz) but every antimatter15-style .splat file fails after the 30-second init timeout with 'Error: Render error: Timeout waiting for splat to initialize'. .ply, .spz, and .sog files render fine.

Repro:
1. node Tools/spark-screenshot/index.js --splat <any .splat file> --output /tmp/out.png
   (e.g. misc/6Splats.splat or misc/RainbowRing.splat from the local Splats collection)
2. Wait ~30 s

Expected: PNG written. Actual: 'Browser error: Failed to load resource: the server responded with a status of 404 (Not Found)' followed by the timeout error; exit code 0 despite the failure (a second bug — failures should exit non-zero).

- `2026-08-11T16:44:22Z`: Not .splat-specific after all: on a full golden-images run 17 files failed (7 .splat, 4 .sog, 6 .spz), and on an immediate re-run all 17 succeeded — including files that had failed twice in isolated repros. The init timeout is flaky (possibly resource contention or a race in the loader wait). The exit-code-0-on-failure bug stands.

---

## 121: Support SPZ v4 format

+++
status: closed
priority: medium
kind: feature
labels: spz, format
created: 2026-08-18T18:11:38Z
updated: 2026-08-18T18:39:44Z
closed: 2026-08-18T18:39:44Z
+++

Niantic released SPZ 4 (https://www.nianticspatial.com/en/blog/spz4). Current SPZReader (Sources/Splats/SPZReader.swift) only handles v2/v3: single GZip stream, 16-byte compressed header, SH degree <= 3.

SPZ 4 is a breaking format change and needs a new read path:

- Magic changed from GZip bytes to plaintext ASCII `NGSP` in a 32-byte header at a fixed offset, OUTSIDE the compressed region. Dispatch on first 4 bytes: `NGSP` -> v4 path, GZip magic -> existing legacy path.
- Payload is no longer one GZip stream. Six independently-compressed ZSTD streams, one per attribute (positions, colors, scales, rotations, alphas, SH), with a table-of-contents (offset/size per stream) up front. Needs a ZSTD decoder (Compression framework has no ZSTD; likely need a dependency or libzstd).
- SH degree 4 now allowed (current code rejects > 3).
- Configurable SH quantization bit depth (3-8 bits) instead of fixed layout.
- Optional vendor extension chain (tagged ID + length + payload; skip unknown). First is Adobe 0xADBE0002 Safe Orbit Camera. Can skip/ignore initially.
- Removed 10M-point cap.

Scope note: v4 read support first. Encode/write is separate. Spec: https://github.com/nianticlabs/spz

---

## 122: CLI stats: report combined gpu total (sort+render)

+++
status: new
priority: low
kind: enhancement
labels: cli, metrics
created: 2026-08-18T18:58:01Z
+++

The splat-render CLI in the sibling project (gaussiansplats-ios) reports a `gpuTotal` stat: sort GPU time + render GPU time summarized per frame (the fastest sort and fastest render need not be on the same frame, so it sums per-frame then takes the median/min, not a sum of summaries).

Our CLI (Sources/metalsprockets-gaussian-splat/Statistics.swift) reports `sortGpu` and `renderGpu` separately but no combined total. Add a `gpuTotal: Stat` computed per-frame as sortGPU.duration + render.duration, then summarized, to both text and JSON output.

---

## 123: CLI stats: command-buffer GPU clock as correlation-free cross-check

+++
status: new
priority: low
kind: enhancement
labels: cli, metrics
created: 2026-08-18T18:58:01Z
+++

The sibling splat-render CLI captures whole-submission GPU time from the command buffer (commandBuffer.gpuEndTime - gpuStartTime) alongside the timestamp-counter-derived per-pass times. It serves as a correlation-free sanity check on the counter numbers (the counters need CPU/GPU timestamp correlation; the command-buffer clock does not).

Our CLI only reports counter-derived GPU times (GPUCounterSample). Add the command-buffer GPU time for the sort and/or render command buffers as a cross-check line in the statistics report. Useful for validating the counter scaling, especially before/after the GPU sort optimization port (see RFC on Desktop).

---

## 124: SplatView: support MetalFX spatial upscaling

+++
status: new
priority: medium
kind: feature
labels: rendering, performance, cli
created: 2026-08-18T19:00:23Z
+++

Add optional MetalFX spatial upscaling to SplatView (Sources/MetalSprocketsGaussianSplats/Spark/SplatView.swift): render the splats at a reduced resolution (e.g. factor 2 = quarter the fragments) and upscale to the final drawable size. A large fragment-cost lever for the Spark/GPU renderers.

MetalFX already exists as first-class MetalSprockets elements (MetalSprockets/Sources/MetalSprockets/Metal/MetalFXSpatial.swift) and MetalSprockets is already a dependency here, so wire those in rather than porting the sibling project’s standalone MetalFXUpscaler. See MetalSprocketsExamples MetalFXDemo for the integration shape.

Scope:
- Opt-in scale factor on SplatView (off/1.0 = no upscaling), plumbed through the render path to an MTLFXSpatialScaler-backed pass.
- Reduced-res offscreen render target + spatial upscale to drawable size; final view size unchanged.
- Graceful fallback when the device does not support MetalFX spatial scaling.
- Wire the same option into the CLI (metalsprockets-gaussian-splat) as a --metalfx <factor> flag, matching the sibling gaussiansplats-ios splat-render, and surface the upscale pass in the statistics per-pass timings.

Out of scope: MetalFX temporal (separate; needs motion vectors + jitter).

---

## 125: Benchmark splat loading across formats

+++
status: closed
priority: low
kind: task
labels: performance, testing, io
created: 2026-08-18T19:00:51Z
updated: 2026-08-18T19:40:42Z
closed: 2026-08-18T19:40:42Z
+++

We have no benchmark for splat-file loading/decoding time. Add one covering the reader paths in Sources/Splats: SPZ (v2/v3 GZip and v4 parallel-ZSTD), PLY, and SOG (CPU + GPU decode).

Goal: measurable, repeatable load timings so we can track regressions and quantify wins (e.g. SPZ v4 parallel decode, SOGReaderGPU vs CPU).

Approach (pick one):
- Swift Testing benchmark test in Tests/ that times reads over the bundled fixtures / Samples (tomatoes.v4.spz, lion.v3.spz, test-grid.*), reporting median/min ms. Keep it out of the default CI gate (GPU/timing-sensitive) or mark not-testable-on-CI like the golden-image suite. The sibling project has SOGReaderBenchmarkTests as prior art.
- Or a `bench-load` subcommand on the metalsprockets-gaussian-splat CLI, reusing the existing Statistics (median/min, warmup/frames, text|json).

Report per format: file size, splat count, decode wall time (median/min), and MB/s. Include SPZ v4 vs v3 to show the parallel-ZSTD speedup.

---

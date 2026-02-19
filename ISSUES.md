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
status: new
priority: low
kind: enhancement
created: 2026-02-19

Architecture refactor: Move sort management from SparkSplatRenderPipeline to the view/renderer layer. Pipeline should be pure function of inputs (splatCloud, sortedIndices, camera matrices) with no @MSState, no async, no sort management.

---


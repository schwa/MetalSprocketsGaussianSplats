## 1: Combine multi and single splat document view
status: closed
priority: medium
kind: none
created: 2026-02-09
updated: 2026-02-12
closed: 2026-02-12

- 2026-02-12: Combined single and multi-splat document views by refactoring SplatDocumentView to use the same MultiCloudRenderView infrastructure as SplatSceneView. Changes include:

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

---

## 2: Fix the splash screen open button to load all file types
status: new
priority: medium
kind: none
created: 2026-02-09


---


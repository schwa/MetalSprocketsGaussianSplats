# MetalSprockets RenderPassDescriptorModifier Bug

## Summary

A regression in MetalSprockets causes tile shading with imageblocks to flash between correct output and magenta on alternating frames.

## Affected Versions

- **Working:** `0d7c74a709571167e9ec6a0d035969966d33a77e` and earlier
- **Broken:** `849e33a6f5761869479f85f8ddbde2c32422af65` and later (up to at least `7e7f67894582b80e9ba5613565c417d663f040fb`)

## Root Cause

Commit `849e33a` ("Fixed #64 - sanitize both descriptor modifiers") changed how `RenderPassDescriptorModifier` applies modifications.

### Old Implementation
```swift
var body: some Element {
    get throws {
        content.environment(\.renderPassDescriptor, try modifiedRenderPassDescriptor())
    }
}

func modifiedRenderPassDescriptor() throws -> MTLRenderPassDescriptor {
    let renderPassDescriptor = renderPassDescriptor.orFatalError("Missing render pass descriptor")
    let copy = (renderPassDescriptor.copy() as? MTLRenderPassDescriptor).orFatalError("Failed to copy render pass descriptor")
    modify(copy)
    return copy
}
```

### New Implementation
```swift
func configureNodeBodyless(_ node: Node) throws {
    guard let renderPassDescriptor = node.environmentValues.renderPassDescriptor else {
        return
    }
    let copy = renderPassDescriptor.copyWithType(MTLRenderPassDescriptor.self)
    modify(copy)
    node.environmentValues.renderPassDescriptor = copy
}
```

The new implementation modifies `node.environmentValues.renderPassDescriptor` directly in `configureNodeBodyless`, which causes the descriptor state to persist or leak between frames.

## Symptoms

- Tile shading renders correctly on one frame, then shows magenta (uninitialized) on the next frame
- This creates a rapid flashing effect
- Affects any use of `.renderPassDescriptorModifier` with tile-related settings:
  - `descriptor.tileWidth`
  - `descriptor.tileHeight`
  - `descriptor.imageblockSampleLength`

## Reproduction

1. Use MetalSprockets at commit `7e7f678` or later
2. Create a render pass with `.renderPassDescriptorModifier` that sets tile properties
3. Observe alternating green/magenta flashing

Example code that exhibits the bug:
```swift
try RenderPass {
    // ... render pipelines using imageblocks ...
}
.renderPassDescriptorModifier { descriptor in
    descriptor.tileWidth = 16
    descriptor.tileHeight = 16
    descriptor.imageblockSampleLength = 16
}
```

## Workaround

Pin MetalSprockets to commit `0d7c74a` or earlier:
```swift
.package(url: "https://github.com/schwa/MetalSprockets", revision: "0d7c74a709571167e9ec6a0d035969966d33a77e"),
```

## Related

- MetalSprockets issue #64
- Commit: https://github.com/schwa/MetalSprockets/commit/849e33a6f5761869479f85f8ddbde2c32422af65

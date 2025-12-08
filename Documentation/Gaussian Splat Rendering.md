# Gaussian Splat Rendering

## On Disk Splat Formats

### .ply

Standard PLY (Polygon File Format) with Gaussian splat properties: position, scale, rotation quaternion, spherical harmonics color coefficients, and opacity in logit space. **~236 bytes/splat** (binary, with SH degree 3) or **~61 bytes/splat** (binary, SH degree 0).

### .splat

Antimatter15's compact binary format with fixed-size records: position (3×float), scale (3×float), color (4×uint8), rotation (4×uint8). **32 bytes/splat**. This format does NOT support spherical harmonics.

### .spz

Niantic's compressed format using gzip compression with quantized positions (24-bit fixed point), 8-bit scales/colors via codebooks, and packed quaternion rotations. **~10-25 bytes/splat** depending on scene complexity.

### .sog

ZIP archive containing PNG textures and JSON metadata with codebook-based compression for scales and spherical harmonics. **~11-17 bytes/splat** for complex scenes.

## Splat Renderers

Three rendering approaches are implemented:

- **Spark**: CPU-sorted back-to-front, alpha blended. Correct transparency, but sorting cost scales with splat count.
- **Stochastic**: No sorting—uses probabilistic alpha testing with depth buffer. Order-independent but introduces noise artifacts.
- **Tile-Based**: GPU binning and per-tile sorting using Metal's tile shading. All work on GPU, but high memory and shader overhead.

## Performance

Tested with 327K splats at 2560×2564 resolution (~6.6 megapixels). These numbers are for relative comparison only and are not indicative of real-world performance on a particular class or classes of device.

| **Renderer** | **Sort CPU (ms)** | **Memory (MiB)** | **Frame (ms)** | **# Encoders** | **# GPU Commands** | **Largest Shader**  | **Shader (ms)** |
| ------------ | ----------------- | ---------------- | -------------- | -------------- | ------------------ | ------------------- | --------------- |
| Spark        | 4.41              | 27.17            | 8.89           | 1              | 1                  | Fragment            | 7.43            |
| Stochastic   | 0                 | 151.32           | 11.17          | 3              | 3                  | Fragment            | 10.31           |
| Tile         | 0                 | 281.94           | 37.2           | 8              | 9                  | Compute (Tile Sort) | 14.92           |

## Renderer Details

### Spark Renderer

A port of the renderer used by [Spark](https://github.com/nianticlabs/spark). This is the most straightforward approach and produces correct transparency.

#### Sorting

Every frame, splats must be sorted back-to-front relative to the camera. The sort key is the Z distance in view space. We use a CPU radix sort (O(n)) which is faster than comparison sorts for large splat counts. Requires a sort buffer of 8 bytes per splat (32-bit index + 32-bit distance). Sorting runs on a background thread and results are double-buffered to avoid stalling the render loop.

#### Rasterization

Splats are rendered as instanced quads (4 vertices, triangle strip). The vertex shader:
1. Fetches the splat from the sorted index buffer
2. Transforms position to view space
3. Computes the 2D covariance matrix by projecting the 3D Gaussian
4. Eigendecomposes to get ellipse axes
5. Expands the quad vertex to cover the ellipse bounds

The fragment shader evaluates the Gaussian falloff based on distance from center and outputs premultiplied alpha. Blending is configured for back-to-front compositing: `src × 1 + dst × (1 - srcAlpha)`.

#### Further Work

- **MetalFX Spatial Upscaling**: Render at reduced resolution and use MetalFX's ML-based spatial upscaler to reconstruct full resolution. Could significantly reduce fragment shader cost (which dominates frame time) while maintaining visual quality.
- **GPU sorting**: Move radix sort to GPU compute shader to free CPU and reduce CPU-GPU synchronization.
- **Aggressive packing**: Reduce memory overhead by packing splats more tightly (e.g., half-precision floats, quantized rotations) and using 16-bit sort indices for scenes under 65K splats.

### Stochastic Renderer

Eliminates sorting entirely by using stochastic alpha testing—each fragment is probabilistically accepted or rejected based on its opacity and a noise value (blue noise or hash-based). Uses depth buffer instead of alpha blending, enabling order-independent rendering at the cost of noise artifacts.

#### How It Works

Instead of sorting splats and alpha-blending them in order, stochastic rendering treats each fragment independently:

1. **Gaussian evaluation**: Compute the splat's opacity at this pixel (base alpha × Gaussian falloff)
2. **High-alpha fast path**: Fragments with alpha > threshold (default 0.95) are always accepted to reduce shimmer on opaque regions
3. **Stochastic test**: Generate a random value; if `random < alpha`, accept the fragment as fully opaque; otherwise discard it
4. **Depth test**: Since accepted fragments are written as opaque (not blended), the depth buffer resolves occlusion regardless of draw order—this is what makes it order-independent and eliminates the need for sorting

The random value can come from:
- **Blue noise texture**: A pre-computed 2D blue noise pattern, offset by frame time and splat index for temporal variation. Produces more visually pleasing noise distribution.
- **PCG hash**: A fast hash function seeded with pixel coordinates, frame time, and splat index. No texture fetch but slightly worse noise distribution.

#### Memory Usage

The stochastic renderer requires additional textures for temporal accumulation:

| Texture | Format | Purpose |
|---------|--------|---------|
| Render texture | BGRA8 | Intermediate render target for current frame |
| Depth texture | Depth32Float | Standard depth buffer for occlusion |
| Accumulation A | BGRA8 | Ping-pong buffer for temporal history |
| Accumulation B | BGRA8 | Ping-pong buffer for temporal history |
| Blue noise | RGBA8 | 64×64 or 128×128 pre-computed noise pattern |

At 2560×2564 resolution, this adds ~100MB for the four full-resolution textures. The stochastic renderer trades Spark's per-splat sort buffer for per-pixel accumulation buffers.

#### Double Buffering (Ping-Pong)

Temporal accumulation uses two accumulation textures that alternate each frame:

```
Frame N (even):   Render → blend(currentFrame, accumA) → accumB → display accumB
Frame N+1 (odd):  Render → blend(currentFrame, accumB) → accumA → display accumA
```

The blend operation is an exponential moving average: `result = mix(history, current, blendFactor)`. The blend factor varies based on camera movement:
- **Stationary** (blendFactor ~0.1): Heavy history weighting, noise averages out over ~10 frames
- **Moving** (blendFactor ~0.5-1.0): More current frame, reduces ghosting/smearing during motion

#### Visual Artifacts

**Noise/Stippling**: The most obvious artifact—semi-transparent regions appear as a dithered/stippled pattern rather than smooth transparency. This is inherent to the stochastic approach. Severity depends on:
- Alpha values (mid-range alphas like 0.3-0.7 show the most noise)
- Noise source (blue noise looks better than white noise hash)
- Whether temporal accumulation is enabled

**Temporal shimmer**: Without accumulation, the random pattern changes every frame, causing visible flickering. With accumulation, this averages out but introduces:

**Ghosting/smearing**: During camera motion, the temporal history briefly shows the old view blended with the new. The adaptive blend factor mitigates this but can't eliminate it entirely—fast camera movements will show brief trails.

**Hard edges on high-alpha regions**: The alpha threshold (default 0.95) causes a hard cutoff—splats above this are always accepted. This can create slightly harder edges than true alpha blending would produce.

**Popping**: Splats near the alpha threshold can "pop" between always-accepted and stochastically-tested as they move or the camera moves, causing subtle discontinuities.

#### Why isn't Stochastic faster?

Despite eliminating CPU sorting (4.41ms saved), Stochastic is slower overall (11.17ms vs 8.89ms). The fragment shader takes 10.31ms vs Spark's 7.43ms. Possible reasons:

- **Overdraw without early-z**: Spark renders back-to-front, but the GPU's early-z optimization can still reject fragments. Stochastic renders in arbitrary order—fragments may be fully shaded only to fail the depth test against an already-written closer fragment.
- **Additional passes**: Stochastic uses 3 encoder passes (render, accumulation blend, blit) vs Spark's single pass.
- **No alpha accumulation culling**: With sorted alpha blending, pixels that reach near-opacity naturally receive diminishing contributions. Stochastic must process every overlapping splat fully.
- **Noise generation overhead**: Each fragment fetches from the blue noise texture or computes a PCG hash—small but non-zero cost across millions of fragments.

#### Further Work

- **Tile-based stochastic hybrid**: Use tile binning to enable early termination when accumulated alpha saturates, recovering the culling benefit of sorted rendering.
- **Multi-sample on-chip averaging**: Do N stochastic samples per pixel within a single tile pass using imageblocks, reducing temporal accumulation latency.

### Metal Tile-Based Renderer

Leverages Metal's tile shading architecture to bin splats into screen-space tiles on the GPU, sort within each tile, and composite using on-chip imageblock memory. Moves all sorting work to the GPU and enables early alpha termination per-tile, but has higher memory overhead and shader complexity.

#### Pipeline Passes

The tile-based renderer uses 5 GPU passes:

1. **Binning Count** (compute): One thread per splat. Each splat computes its screen-space bounding box, determines which tiles it overlaps, and atomically increments per-tile counters.

2. **Prefix Sum** (compute): Computes exclusive prefix sum of tile counts to determine write offsets. After this pass, `tileOffsets[i]` contains the starting index for tile `i` in the compacted buffer.

3. **Binning Write** (compute): One thread per splat again. Re-computes tile overlaps and writes `TileSplatIndex` (splat ID + depth) to the compacted buffer at `tileOffsets[tile] + localIndex`.

4. **Per-Tile Sort** (compute): One thread per tile. Each tile runs an in-place 4-pass radix sort (8-bit keys, LSB-first) on its splat indices, sorting by depth front-to-back. Uses ping-pong between two buffers.

5. **Tile Render** (fragment + imageblock): Full-screen quad triggers fragment shader for each pixel. Fragment reads its tile's sorted splat list, evaluates each splat's Gaussian contribution, and accumulates color front-to-back with early termination when alpha saturates. Result is written to imageblock, then blitted to the color attachment.

#### Memory Usage

| Buffer | Size | Purpose |
|--------|------|---------|
| `tileSplatIndicesA` | 128 MB | Compacted splat indices + depths (ping buffer) |
| `tileSplatIndicesB` | 128 MB | Compacted splat indices + depths (pong buffer) |
| `tileCounters` | 4 bytes × numTiles | Atomic counters for binning |
| `tileOffsets` | 4 bytes × (numTiles+1) | Prefix sum results |

Each `TileSplatIndex` is 8 bytes (32-bit splat ID + 32-bit depth). The buffers are sized for 16M entries: 8 bytes × 16M = 128 MB each. This assumes each splat overlaps ~8 tiles on average—enough for ~2M splats. The two ping-pong buffers together consume **256 MB**, which dominates memory usage.

#### Why It's Slow

Despite doing all sorting on the GPU, the tile-based renderer is currently the slowest (37.2ms vs Spark's 8.89ms):

- **Redundant splat processing**: Binning requires processing each splat twice (count pass + write pass) because we can't know write offsets until after counting.
- **Per-tile serial sort**: Each tile's radix sort runs on a single thread, iterating through potentially thousands of splats. The sort kernel alone takes 14.92ms.
- **No early culling**: Every visible splat is binned to every tile it overlaps, even if that tile's pixels are already saturated from closer splats.
- **Fragment shader overhead**: The tile fragment shader re-transforms each splat from world space, recomputes covariance, and evaluates the Gaussian—duplicating work the vertex shader would normally do once.

#### Further Work

- **MetalFX Spatial Upscaling**: Render at reduced resolution to reduce tile count and per-tile splat lists.
- **Tighter tile-splat intersection**: Currently uses AABB overlap; could test against the actual Gaussian ellipse to reduce false positives and shrink per-tile splat lists.
- **Per-tile splat limit**: Cap splats per tile to bound worst-case sort time. When over limit, discard using heuristics: lowest alpha, furthest from camera, smallest screen-space area, or lowest alpha × area (visual contribution).
- **Parallel per-tile sort**: Use threadgroup parallelism within each tile instead of single-threaded radix sort.
- **Visibility buffer**: First pass writes visible splat IDs per pixel (cheap), second pass shades only those splats. Avoids evaluating Gaussians for completely occluded splats and decouples visibility from shading.
- **Splat caching**: Splats are transformed twice; caching screen-space position and 2D covariance during binning would avoid recomputation in the fragment shader.

#import "GaussianSplatShaders.h"

#import <metal_stdlib>

using namespace metal;

// GPU splat sort: an 8-bit LSD radix over the 16-bit `half` distance key.
// Two passes (shift 0, 8) sort a 16-bit key. Ported from the GPUSort benchmark
// project's 8-bit radix (the steady iOS winner), specialized to build and carry
// `IndexedDistance` payloads. Intermediate records are `uint2` (see SplatGPUSort.h).

namespace SplatGPUSort {

constant uint RADIX = 256;

// Map an IEEE-754 half bit-pattern to a ushort that sorts in ascending order,
// including negatives. Branchless. Mirrors floatFlip16() on the Swift side.
inline ushort floatFlip16(ushort f) {
    ushort mask = ushort(short(f) >> 15) | 0x8000u;
    return f ^ mask;
}

inline ushort floatUnflip16(ushort u) {
    return (u & 0x8000u) ? (u ^ 0x8000u) : ushort(~u);
}

// Frustum test in clip space (Metal depth range [0, w]). `guardBand` keeps
// splats whose center is just outside the edges (their quad may still reach in).
// The dominant, artifact-free cull is `clip.w <= 0` — splats behind the eye,
// which for an interior view is ~half of them.
inline bool splatPassesCull(float4 clip, float guardBand) {
    if (clip.w <= 0.0) return false;                       // behind camera / at eye
    float wx = clip.w * (1.0 + guardBand);
    if (clip.x < -wx || clip.x > wx) return false;         // left / right
    if (clip.y < -wx || clip.y > wx) return false;         // bottom / top
    if (clip.z > clip.w) return false;                     // beyond far plane
    if (clip.z < -guardBand * clip.w) return false;        // behind near plane
    return true;
}

// Reset the indirect draw arguments before culling. Layout matches
// MTLDrawPrimitivesIndirectArguments { vertexCount, instanceCount, vertexStart,
// baseInstance }. instanceCount is the atomic survivor counter the cull kernel
// increments and the render pass draws with.
//
// Stable pre-sort compaction (3 phases): mark -> scan blocks -> scatter. Culled
// splats are dropped BEFORE the radix so the sort processes only survivors, and
// survivors keep their original gid order so equal-key ties stay temporally
// stable (no shimmer). Blocks are fixed contiguous ranges of COMPACT_BLOCK
// elements; block index == threadgroup index, so the dispatch must be uniform.
constant ushort kCulledKey = 0xFFFFu;
constant ushort kMaxSurvivorKey = 0xFFFEu;
constant uint COMPACT_BLOCK = 512;

// Phase 1: per-splat cull + distance. Build the sort record
// { flippedKey|cloud, splatIndex } in place at records[gid]; culled splats get
// the sentinel key 0xFFFF (survivors clamp to 0xFFFE so the sentinel is
// unambiguous). Tally survivors per block into blockCounts[block].
kernel void splatCullMark(device const SparkSplat  *splats      [[buffer(0)]],
                          device uint2             *records     [[buffer(1)]],
                          constant SplatDistanceParams &p        [[buffer(2)]],
                          device uint              *blockCounts  [[buffer(3)]],
                          uint gid     [[thread_position_in_grid]],
                          uint lid     [[thread_position_in_threadgroup]],
                          uint groupId [[threadgroup_position_in_grid]]) {
    threadgroup atomic_uint tgCount;
    if (lid == 0) { atomic_store_explicit(&tgCount, 0u, memory_order_relaxed); }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid < p.numElements) {
        float3 position = float3(splats[gid].position);
        float4 viewPos = p.modelView * float4(position, 1.0);
        bool alive = (p.cullEnabled == 0) || splatPassesCull(p.projection * viewPos, p.guardBand);
        if (!alive && p.viewCount > 1) {
            // Stereo: keep splats visible to either eye so per-eye visibility
            // never causes incorrect culling.
            float4 viewPos1 = p.modelView1 * float4(position, 1.0);
            alive = splatPassesCull(p.projection1 * viewPos1, p.guardBand);
        }
        float distance = viewPos.z * (p.reversed ? -1.0 : 1.0);
        ushort key = alive ? min(floatFlip16(as_type<ushort>(half(distance))), kMaxSurvivorKey)
                           : kCulledKey;
        records[gid] = uint2(uint(key) | (p.cloudIndex << 16), gid);
        if (alive) { atomic_fetch_add_explicit(&tgCount, 1u, memory_order_relaxed); }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (lid == 0) { blockCounts[groupId] = atomic_load_explicit(&tgCount, memory_order_relaxed); }
}

// Phase 2 (single thread): exclusive prefix sum of the per-block survivor counts
// -> blockBase, and the grand total into the indirect draw args. Layout matches
// MTLDrawPrimitivesIndirectArguments { vertexCount, instanceCount, vertexStart,
// baseInstance }; instanceCount is the survivor count the render pass draws.
kernel void splatCompactScanBlocks(device const uint *blockCounts [[buffer(0)]],
                                   device uint        *blockBase   [[buffer(1)]],
                                   device uint        *drawArgs    [[buffer(2)]],
                                   constant uint      &numBlocks   [[buffer(3)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (gid != 0) return;
    uint running = 0;
    for (uint b = 0; b < numBlocks; b++) {
        blockBase[b] = running;
        running += blockCounts[b];
    }
    drawArgs[0] = 4;         // vertexCount: quad as a 4-vertex triangle strip
    drawArgs[1] = running;   // instanceCount: survivor count
    drawArgs[2] = 0;         // vertexStart
    drawArgs[3] = 0;         // baseInstance
}

// Phase 3: compact survivors into outRecords[blockBase[block] + localRank],
// where localRank is the exclusive prefix sum of the alive flag within the
// block. Block order + in-block lid order == original gid order => stable.
kernel void splatCompactScatter(device const uint2 *inRecords   [[buffer(0)]],
                                device uint2       *outRecords  [[buffer(1)]],
                                device const uint  *blockBase   [[buffer(2)]],
                                constant uint      &numElements [[buffer(3)]],
                                uint gid     [[thread_position_in_grid]],
                                uint lid     [[thread_position_in_threadgroup]],
                                uint groupId [[threadgroup_position_in_grid]],
                                uint tsize   [[threads_per_threadgroup]]) {
    threadgroup uint s[COMPACT_BLOCK];
    bool alive = false;
    uint2 rec = uint2(0u, 0u);
    if (gid < numElements) {
        rec = inRecords[gid];
        alive = (rec.x & 0xFFFFu) != uint(kCulledKey);
    }

    // In-place Hillis-Steele inclusive scan of the alive flags (double barrier
    // per step avoids the intra-step read/write hazard); exclusive = inclusive
    // minus this thread's own flag.
    s[lid] = alive ? 1u : 0u;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint offset = 1; offset < tsize; offset <<= 1) {
        uint add = (lid >= offset) ? s[lid - offset] : 0u;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        s[lid] += add;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    uint localRank = s[lid] - (alive ? 1u : 0u);

    if (alive) { outRecords[blockBase[groupId] + localRank] = rec; }
}

// One threadgroup per tile: cooperative digit histogram in threadgroup memory.
// hist layout is digit-major: hist[digit * numTiles + tile].
kernel void splatRadixHistogram(device const uint2 *records [[buffer(0)]],
                                device uint         *hist    [[buffer(1)]],
                                constant SplatSortParams &p   [[buffer(2)]],
                                device const uint   *drawArgs [[buffer(3)]],
                                uint tile  [[threadgroup_position_in_grid]],
                                uint lid   [[thread_position_in_threadgroup]],
                                uint tsize [[threads_per_threadgroup]]) {
    uint numElements = drawArgs[1];   // survivor count (compacted to the front)
    threadgroup atomic_uint tgHist[256];
    for (uint d = lid; d < RADIX; d += tsize) {
        atomic_store_explicit(&tgHist[d], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint start = tile * p.elementsPerTile;
    uint end   = min(start + p.elementsPerTile, numElements);
    for (uint i = start + lid; i < end; i += tsize) {
        uint digit = (records[i].x >> p.shift) & 0xFFu;
        atomic_fetch_add_explicit(&tgHist[digit], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint d = lid; d < RADIX; d += tsize) {
        hist[d * p.numTiles + tile] = atomic_load_explicit(&tgHist[d], memory_order_relaxed);
    }
}

// One thread per digit: exclusive prefix sum of that digit's counts across tiles,
// and the per-digit total.
kernel void splatRadixScanOffsets(device const uint *hist     [[buffer(0)]],
                                  device uint        *offset   [[buffer(1)]],
                                  device uint        *total    [[buffer(2)]],
                                  constant SplatSortParams &p    [[buffer(3)]],
                                  device const uint  *drawArgs  [[buffer(4)]],
                                  uint digit [[thread_position_in_grid]]) {
    if (digit >= RADIX) return;
    // Only tiles covering survivors were histogrammed; scan just those. Tiles
    // past the survivors are all zero, so `running` (the digit total) is
    // unaffected and their unused offsets need not be written.
    uint usedTiles = min((drawArgs[1] + p.elementsPerTile - 1) / p.elementsPerTile, p.numTiles);
    uint running = 0;
    uint base = digit * p.numTiles;
    for (uint t = 0; t < usedTiles; t++) {
        offset[base + t] = running;
        running += hist[base + t];
    }
    total[digit] = running;
}

// Single thread: exclusive prefix sum of the 256 digit totals.
kernel void splatRadixScanDigitBase(device const uint *total     [[buffer(0)]],
                                    device uint        *digitBase [[buffer(1)]],
                                    uint gid [[thread_position_in_grid]]) {
    if (gid != 0) return;
    uint running = 0;
    for (uint d = 0; d < RADIX; d++) {
        digitBase[d] = running;
        running += total[d];
    }
}

// When set, the scatter writes decoded IndexedDistance records (same 8-byte
// stride as uint2) instead of raw sort records, so the final radix pass replaces
// the separate splatDecodeIndices kernel + its full-buffer roundtrip.
constant bool decode_output [[function_constant(6)]];

// One SIMD-group per tile: stable scatter into the output buffer. Lane-order +
// chunk-order == input order => stable.
kernel void splatRadixScatter(device const uint2 *inRecords  [[buffer(0)]],
                              device uint2        *outRecords [[buffer(1)]],
                              device const uint   *offset     [[buffer(2)]],
                              device const uint   *digitBase  [[buffer(3)]],
                              constant SplatSortParams &p      [[buffer(4)]],
                              device const uint   *drawArgs    [[buffer(5)]],
                              uint tile  [[threadgroup_position_in_grid]],
                              uint lane  [[thread_position_in_threadgroup]],
                              uint tsize [[threads_per_threadgroup]]) {
    uint numElements = drawArgs[1];   // survivor count (compacted to the front)
    threadgroup uint cursor[256];
    for (uint d = lane; d < RADIX; d += tsize) {
        cursor[d] = digitBase[d] + offset[d * p.numTiles + tile];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint start = tile * p.elementsPerTile;
    uint end   = min(start + p.elementsPerTile, numElements);
    // Guard the unsigned subtraction: when the sort count (survivor count) is
    // smaller than the full-count tile grid, tiles past the survivors have
    // start > numElements and `end - start` would underflow to a huge uint.
    uint n     = end > start ? end - start : 0u;

    for (uint chunk = 0; chunk < p.elementsPerTile; chunk += tsize) {
        uint local  = chunk + lane;
        bool active = local < n;
        uint2 rec   = active ? inRecords[start + local] : uint2(0u, 0u);
        uint digit  = active ? ((rec.x >> p.shift) & 0xFFu) : 0u;

        // Rank same-digit peers with per-bit ballots: peers = active lanes whose
        // digit matches on every bit. 8 ballots + popcounts instead of a
        // 32-iteration shuffle loop. Lane order within peers is preserved, so the
        // scatter stays stable.
        uint peers = uint((simd_vote::vote_t)simd_ballot(active));
        for (uint b = 0; b < 8; b++) {
            bool bit = (digit >> b) & 1u;
            uint ball = uint((simd_vote::vote_t)simd_ballot(bit));
            peers &= bit ? ball : ~ball;
        }
        uint rank  = popcount(peers & ((1u << lane) - 1u));
        uint total = popcount(peers);

        threadgroup_barrier(mem_flags::mem_threadgroup);
        uint base = active ? cursor[digit] : 0u;
        if (active) {
            if (decode_output) {
                IndexedDistance out;
                out.splatIndex = rec.y;
                out.cloudIndex = ushort(rec.x >> 16);
                out.distanceToCamera = as_type<half>(floatUnflip16(ushort(rec.x & 0xFFFFu)));
                ((device IndexedDistance *)outRecords)[base + rank] = out;
            } else {
                outRecords[base + rank] = rec;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (active && rank == 0) cursor[digit] += total;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

} // namespace SplatGPUSort

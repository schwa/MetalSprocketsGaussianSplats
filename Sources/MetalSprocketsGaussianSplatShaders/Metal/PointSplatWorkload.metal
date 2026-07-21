#import "GaussianSplatShaders.h"

#import <metal_stdlib>

using namespace metal;

// Work distribution for the PointSplat renderer (RFC 0003, paper Sec. 3.2).
//
// Input: per-Gaussian point counts n_g. Output: an indices array where
// indices[t] is the Gaussian that splat-thread t samples from, sorted by
// Gaussian index (cache-coherent reads in the splat stage).
//
// Pipeline: exclusive prefix sum over counts -> t_g, scatter g into
// indices[t_g] for n_g != 0 (zero-initialized array), then an inclusive
// max-scan makes the sequence monotonic. Uses the same 256-element
// block-scan skeleton as SplatGPUSort's compaction.

namespace PointSplatWorkload {

    constant uint WORKLOAD_BLOCK = 256;

    // Phase 1: per-block exclusive prefix sum of counts. Writes each
    // element's exclusive-within-block prefix and the block's total.
    kernel void workloadScanCountsBlock(device const uint *counts      [[buffer(0)]],
                                        device uint       *localPrefix [[buffer(1)]],
                                        device uint       *blockSums   [[buffer(2)]],
                                        constant uint     &numElements [[buffer(3)]],
                                        uint gid     [[thread_position_in_grid]],
                                        uint lid     [[thread_position_in_threadgroup]],
                                        uint groupId [[threadgroup_position_in_grid]],
                                        uint tsize   [[threads_per_threadgroup]]) {
        threadgroup uint s[WORKLOAD_BLOCK];
        uint count = (gid < numElements) ? counts[gid] : 0u;

        // Hillis-Steele inclusive scan; double barrier avoids the intra-step
        // read/write hazard. Exclusive = inclusive minus own value.
        s[lid] = count;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint offset = 1; offset < tsize; offset <<= 1) {
            uint add = (lid >= offset) ? s[lid - offset] : 0u;
            threadgroup_barrier(mem_flags::mem_threadgroup);
            s[lid] += add;
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        if (gid < numElements) {
            localPrefix[gid] = s[lid] - count;
        }
        if (lid == tsize - 1) {
            blockSums[groupId] = s[lid];
        }
    }

    // Phase 2 (single thread): exclusive scan of block sums -> block bases,
    // grand total (= number of splat threads) into totals[0].
    kernel void workloadScanBlockSums(device const uint *blockSums [[buffer(0)]],
                                      device uint       *blockBase [[buffer(1)]],
                                      device uint       *totals    [[buffer(2)]],
                                      constant uint     &numBlocks [[buffer(3)]],
                                      uint gid [[thread_position_in_grid]]) {
        if (gid != 0) {
            return;
        }
        uint running = 0;
        for (uint b = 0; b < numBlocks; b++) {
            blockBase[b] = running;
            running += blockSums[b];
        }
        totals[0] = running;
    }

    // Phase 2.5: zero the indices array ahead of the scatter, so the whole
    // pipeline can run in one compute encoder without a blit fill.
    kernel void workloadClearIndices(device uint   *indices  [[buffer(0)]],
                                     constant uint &capacity [[buffer(1)]],
                                     uint gid [[thread_position_in_grid]]) {
        if (gid < capacity) {
            indices[gid] = 0;
        }
    }

    // Phase 3: scatter Gaussian index g into indices[t_g] where t_g is the
    // global exclusive prefix sum. indices must be zero-initialized.
    // Entries past `capacity` are dropped (points silently missing, per paper).
    kernel void workloadScatterIndices(device const uint *counts      [[buffer(0)]],
                                       device const uint *localPrefix [[buffer(1)]],
                                       device const uint *blockBase   [[buffer(2)]],
                                       device uint       *indices     [[buffer(3)]],
                                       constant uint     &numElements [[buffer(4)]],
                                       constant uint     &capacity    [[buffer(5)]],
                                       uint gid     [[thread_position_in_grid]],
                                       uint groupId [[threadgroup_position_in_grid]]) {
        if (gid >= numElements || counts[gid] == 0) {
            return;
        }
        uint t = blockBase[groupId] + localPrefix[gid];
        if (t < capacity) {
            indices[t] = gid;
        }
    }

    // Phase 4: per-block inclusive max-scan of the scattered indices, in
    // place. Writes each block's maximum for the carry pass.
    kernel void workloadMaxScanBlock(device uint   *indices     [[buffer(0)]],
                                     device uint   *blockMaxes  [[buffer(1)]],
                                     constant uint &numElements [[buffer(2)]],
                                     uint gid     [[thread_position_in_grid]],
                                     uint lid     [[thread_position_in_threadgroup]],
                                     uint groupId [[threadgroup_position_in_grid]],
                                     uint tsize   [[threads_per_threadgroup]]) {
        threadgroup uint s[WORKLOAD_BLOCK];
        uint value = (gid < numElements) ? indices[gid] : 0u;

        s[lid] = value;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint offset = 1; offset < tsize; offset <<= 1) {
            uint other = (lid >= offset) ? s[lid - offset] : 0u;
            threadgroup_barrier(mem_flags::mem_threadgroup);
            s[lid] = max(s[lid], other);
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        if (gid < numElements) {
            indices[gid] = s[lid];
        }
        if (lid == tsize - 1) {
            blockMaxes[groupId] = s[lid];
        }
    }

    // Phase 5 (single thread): exclusive running max over block maxima.
    kernel void workloadScanBlockMaxes(device const uint *blockMaxes [[buffer(0)]],
                                       device uint       *blockCarry [[buffer(1)]],
                                       constant uint     &numBlocks  [[buffer(2)]],
                                       uint gid [[thread_position_in_grid]]) {
        if (gid != 0) {
            return;
        }
        uint carry = 0;
        for (uint b = 0; b < numBlocks; b++) {
            blockCarry[b] = carry;
            carry = max(carry, blockMaxes[b]);
        }
    }

    // Phase 6: fold the carry from preceding blocks into each element.
    kernel void workloadApplyBlockMax(device uint       *indices     [[buffer(0)]],
                                      device const uint *blockCarry  [[buffer(1)]],
                                      constant uint     &numElements [[buffer(2)]],
                                      uint gid     [[thread_position_in_grid]],
                                      uint groupId [[threadgroup_position_in_grid]]) {
        if (gid >= numElements) {
            return;
        }
        indices[gid] = max(indices[gid], blockCarry[groupId]);
    }

} // namespace PointSplatWorkload

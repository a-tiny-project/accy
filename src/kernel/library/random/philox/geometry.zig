const random = @import("../root.zig");

const base = random.base;
const block = random.block;

const geometry_mod = base.geometry_mod;
const philox_lanes = block.philox_lanes;
const ceilDiv = block.ceilDiv;
const random_thread_caps = base.random_thread_caps;

pub fn philoxThreadsForCount(count: u64) u32 {
    return geometry_mod.threadsForExtent(ceilDiv(count, philox_lanes), random_thread_caps);
}

pub fn philoxThreadCandidatesForCount(count: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(ceilDiv(count, philox_lanes), random_thread_caps);
}

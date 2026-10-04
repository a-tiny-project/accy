const random = @import("../root.zig");

const base = random.base;
const block = random.block;

const geometry_mod = base.geometry_mod;
const threefry_lanes = block.threefry_lanes;
const ceilDiv = block.ceilDiv;
const random_thread_caps = base.random_thread_caps;

pub fn threefryThreadsForCount(count: u64) u32 {
    return geometry_mod.threadsForExtent(ceilDiv(count, threefry_lanes), random_thread_caps);
}

pub fn threefryThreadCandidatesForCount(count: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(
        ceilDiv(count, threefry_lanes),
        random_thread_caps,
    );
}

const random = @import("../root.zig");

const base = random.base;

const geometry_mod = base.geometry_mod;
const random_thread_caps = base.random_thread_caps;

pub fn squaresThreadsForCount(count: u64) u32 {
    return geometry_mod.threadsForExtent(count, random_thread_caps);
}

pub fn squaresThreadCandidatesForCount(count: u64) geometry_mod.Thread1DCandidates {
    return geometry_mod.threadCandidatesForExtent(count, random_thread_caps);
}

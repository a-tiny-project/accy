const library = @import("../../../root.zig");

const entry = library.entry;

pub fn threadBlocksMatch(specialization: entry.Specialization, threads: u32) bool {
    const launch = specialization.launch orelse return false;
    return launch.threadgroup[0] == threads;
}

pub fn directThreadBlocksMatch(specialization: entry.Specialization, threads: u32) bool {
    if (specialization.structure != null and !specialization.structureIs("direct")) return false;
    return threadBlocksMatch(specialization, threads);
}

pub fn sharedBinsThreadBlocksMatch(specialization: entry.Specialization, threads: u32) bool {
    if (!specialization.structureIs("shared_bins")) return false;
    return threadBlocksMatch(specialization, threads);
}

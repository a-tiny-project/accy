const std = @import("std");
const capacity = @import("capacity.zig");

const gibibyte: u64 = 1024 * 1024 * 1024;
const mebibyte: u64 = 1024 * 1024;

pub fn processCount(b: *std.Build, requested: u32) u32 {
    return capacity.ordinary.slots(hostCapacity(
        b,
        capacity.ordinary.memory_reserve +
            capacity.fallback_memory_bytes,
    ), requested);
}

pub fn hostCapacity(b: *std.Build, fallback_memory: u64) capacity.Capacity {
    return capacity.host(&b.graph.environ_map, fallback_memory) catch
        @panic("invalid build resource capacity environment");
}

pub fn ordinaryMemoryReserve() u64 {
    return capacity.ordinary.memory_reserve;
}

pub fn treeBudgetBytes(tree_bytes: u64) u64 {
    return capacity.treeBudgetBytes(tree_bytes);
}

pub fn testStepMemoryBytes() u64 {
    return capacity.test_step_memory_bytes;
}

pub fn compileStepMemoryBytes() u64 {
    return capacity.compile_step_memory_bytes;
}

pub fn ordinaryMemoryClaimMib() u32 {
    return @intCast(capacity.ordinary.process_memory_claim / mebibyte);
}

pub fn heavyMemoryClaimMib() u32 {
    return @intCast(capacity.heavy.process_memory_claim / mebibyte);
}

pub fn buildCpuClaim() u16 {
    return @intCast(capacity.buildCpuClaim());
}

pub fn automaticProcessCount(
    cpu_count: usize,
    total_memory: u64,
    requested: u32,
) u32 {
    std.debug.assert(requested > 0);
    std.debug.assert(cpu_count > 0);
    std.debug.assert(cpu_count <= std.math.maxInt(u32));
    return capacity.ordinary.slots(
        capacity.Capacity.init(cpu_count, total_memory),
        requested,
    );
}

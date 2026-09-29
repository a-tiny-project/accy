const std = @import("std");
const topology = @import("../root.zig");

const CpuSet = extern struct {
    bits: [topology.max_logical_processors / @bitSizeOf(c_ulong)]c_ulong,
};

extern "c" fn cpuset_getaffinity(
    level: c_int,
    which: c_int,
    id: i64,
    set_size: usize,
    set: *CpuSet,
) c_int;

extern "c" fn cpuset_setaffinity(
    level: c_int,
    which: c_int,
    id: i64,
    set_size: usize,
    set: *const CpuSet,
) c_int;

const CpuSetAdder = struct {
    set: *CpuSet,

    pub fn call(self: *@This(), lp: usize) void {
        const word = lp / @bitSizeOf(c_ulong);
        const bit: std.math.Log2Int(c_ulong) =
            @intCast(lp % @bitSizeOf(c_ulong));
        self.set.bits[word] |= @as(c_ulong, 1) << bit;
    }
};

pub fn getThreadAffinity(out: *topology.LogicalProcessorSet) bool {
    var set = CpuSet{ .bits = @splat(0) };
    if (cpuset_getaffinity(3, 1, -1, @sizeOf(CpuSet), &set) != 0) return false;
    out.* = .{};
    for (set.bits, 0..) |word, word_index| {
        var remaining = word;
        while (remaining != 0) {
            const bit: usize = @ctz(remaining);
            out.set(word_index * @bitSizeOf(c_ulong) + bit);
            remaining &= remaining - 1;
        }
    }
    return true;
}

pub fn setThreadAffinity(lps: *const topology.LogicalProcessorSet) bool {
    var set = CpuSet{ .bits = @splat(0) };
    var add = CpuSetAdder{ .set = &set };
    lps.foreach(&add);
    return cpuset_setaffinity(3, 1, -1, @sizeOf(CpuSet), &set) == 0;
}

comptime {
    std.debug.assert(@sizeOf(CpuSet) == 128);
}

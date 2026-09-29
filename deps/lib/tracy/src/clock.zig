const std = @import("std");
const sys = @import("sys");

pub fn nowNs() u64 {
    const raw = sys.time.nanoTimestamp();
    if (raw <= 0) return 0;
    if (raw > std.math.maxInt(u64)) return std.math.maxInt(u64);
    return @intCast(raw);
}

pub fn threadId() u64 {
    return @intCast(sys.thread.currentId());
}

test "clock values are stable enough for trace metadata" {
    try std.testing.expectEqual(threadId(), threadId());
}

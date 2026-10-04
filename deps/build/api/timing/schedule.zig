const std = @import("std");

pub const Schedule = struct {
    order: []const u32,
    next_ordinal: std.atomic.Value(usize) = .init(0),

    pub fn take(self: *Schedule) ?u32 {
        const ordinal = self.next_ordinal.fetchAdd(1, .monotonic);
        if (ordinal >= self.order.len) return null;
        return self.order[ordinal];
    }
};

pub fn activeCount(requested: usize, test_count: usize) usize {
    return @min(requested, test_count);
}

pub fn indexedPosition(
    total: usize,
    worker_count: usize,
    worker_index: usize,
    worker_ordinal: usize,
) ?usize {
    std.debug.assert(worker_count > 0);
    std.debug.assert(worker_index < worker_count);
    const offset = std.math.mul(usize, worker_ordinal, worker_count) catch
        return null;
    const position = std.math.add(usize, worker_index, offset) catch
        return null;
    if (position >= total) return null;
    return position;
}

const std = @import("std");

pub const Removal = struct {
    requested_bytes: usize,
    tracked_bytes: usize,

    pub fn untrackedBytes(self: Removal) usize {
        return self.requested_bytes - self.tracked_bytes;
    }
};

const Mapping = struct {
    start: usize,
    end: usize,
};

pub const Ledger = struct {
    ranges: std.ArrayListUnmanaged(Mapping) = .empty,
    mapped_bytes: usize = 0,

    pub fn deinit(self: *Ledger, allocator: std.mem.Allocator) void {
        self.ranges.deinit(allocator);
        self.* = undefined;
    }

    pub fn map(
        self: *Ledger,
        allocator: std.mem.Allocator,
        address: usize,
        len: usize,
    ) !usize {
        if (len == 0) return 0;
        const end = std.math.add(usize, address, len) catch
            return error.InvalidMappingRange;
        try self.ranges.ensureUnusedCapacity(allocator, 2);
        const displaced = self.removeRange(address, end);
        var start = address;
        var merged_end = end;
        var index = self.insertionIndex(address);
        if (index > 0 and self.ranges.items[index - 1].end == start) {
            start = self.ranges.items[index - 1].start;
            _ = self.ranges.orderedRemove(index - 1);
            index -= 1;
        }
        if (index < self.ranges.items.len and
            self.ranges.items[index].start == merged_end)
        {
            merged_end = self.ranges.items[index].end;
            _ = self.ranges.orderedRemove(index);
        }
        self.ranges.insertAssumeCapacity(index, .{
            .start = start,
            .end = merged_end,
        });
        self.mapped_bytes = self.mapped_bytes - displaced + len;
        return displaced;
    }

    pub fn unmap(
        self: *Ledger,
        allocator: std.mem.Allocator,
        address: usize,
        len: usize,
    ) !Removal {
        if (len == 0) return .{
            .requested_bytes = 0,
            .tracked_bytes = 0,
        };
        const end = std.math.add(usize, address, len) catch
            return error.InvalidMappingRange;
        try self.ranges.ensureUnusedCapacity(allocator, 1);
        const tracked = self.removeRange(address, end);
        self.mapped_bytes -= tracked;
        return .{
            .requested_bytes = len,
            .tracked_bytes = tracked,
        };
    }

    pub fn count(self: *const Ledger) usize {
        return self.ranges.items.len;
    }

    fn removeRange(self: *Ledger, start: usize, end: usize) usize {
        var removed: usize = 0;
        var index: usize = 0;
        while (index < self.ranges.items.len) {
            const current = self.ranges.items[index];
            if (current.end <= start) {
                index += 1;
                continue;
            }
            if (current.start >= end) break;
            const overlap_start = @max(current.start, start);
            const overlap_end = @min(current.end, end);
            removed += overlap_end - overlap_start;
            if (start <= current.start and end >= current.end) {
                _ = self.ranges.orderedRemove(index);
                continue;
            }
            if (start <= current.start) {
                self.ranges.items[index].start = end;
                index += 1;
                continue;
            }
            if (end >= current.end) {
                self.ranges.items[index].end = start;
                index += 1;
                continue;
            }
            self.ranges.items[index].end = start;
            self.ranges.insertAssumeCapacity(index + 1, .{
                .start = end,
                .end = current.end,
            });
            index += 2;
        }
        return removed;
    }

    fn insertionIndex(self: *const Ledger, address: usize) usize {
        var low: usize = 0;
        var high = self.ranges.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.ranges.items[middle].start < address) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low;
    }
};

test "mapping ledger handles trim split replacement and adjacency" {
    var ledger: Ledger = .{};
    defer ledger.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        @as(usize, 0),
        try ledger.map(std.testing.allocator, 0x1000, 0x4000),
    );
    const prefix = try ledger.unmap(
        std.testing.allocator,
        0x1000,
        0x1000,
    );
    try std.testing.expectEqual(@as(usize, 0), prefix.untrackedBytes());
    const middle = try ledger.unmap(
        std.testing.allocator,
        0x3000,
        0x1000,
    );
    try std.testing.expectEqual(@as(usize, 0x1000), middle.tracked_bytes);
    try std.testing.expectEqual(@as(usize, 0x2000), ledger.mapped_bytes);
    try std.testing.expectEqual(@as(usize, 2), ledger.count());

    try std.testing.expectEqual(
        @as(usize, 0x1000),
        try ledger.map(std.testing.allocator, 0x3000, 0x2000),
    );
    try std.testing.expectEqual(@as(usize, 0x3000), ledger.mapped_bytes);
    try std.testing.expectEqual(@as(usize, 1), ledger.count());
}

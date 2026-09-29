const std = @import("std");
const output = @import("output.zig");

pub const CapacityError = error{
    RetainedOutputsEmpty,
    CapacityOverflow,
};

pub const Capacity = struct {
    retained_output_count: usize,
    retained_output_bytes: usize,

    pub fn derive(retained_output_count: usize) CapacityError!Capacity {
        if (retained_output_count == 0) return error.RetainedOutputsEmpty;
        const retained_output_bytes = std.math.mul(
            usize,
            retained_output_count,
            @sizeOf(output.Output),
        ) catch return error.CapacityOverflow;
        return .{
            .retained_output_count = retained_output_count,
            .retained_output_bytes = retained_output_bytes,
        };
    }
};

pub const OutputStorage = struct {
    allocator: std.mem.Allocator = undefined,
    items: []output.Output = &.{},
    count: usize = 0,
    capacity_rejection_count: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!OutputStorage {
        std.debug.assert(capacity.retained_output_count > 0);
        std.debug.assert(
            capacity.retained_output_bytes / @sizeOf(output.Output) ==
                capacity.retained_output_count,
        );
        return .{
            .allocator = allocator,
            .items = try allocator.alloc(output.Output, capacity.retained_output_count),
        };
    }

    pub fn deinit(self: *OutputStorage) void {
        std.debug.assert(self.count <= self.items.len);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = .{};
    }

    pub fn retained(self: *const OutputStorage) []const output.Output {
        std.debug.assert(self.count <= self.items.len);
        return self.items[0..self.count];
    }

    pub fn retainedMut(self: *OutputStorage) []output.Output {
        std.debug.assert(self.count <= self.items.len);
        return self.items[0..self.count];
    }

    pub fn reserve(self: *OutputStorage) ?usize {
        std.debug.assert(self.count <= self.items.len);
        if (self.count < self.items.len) return self.count;
        self.capacity_rejection_count +|= 1;
        return null;
    }

    pub fn commit(self: *OutputStorage, index: usize, value: output.Output) void {
        std.debug.assert(index == self.count);
        std.debug.assert(index < self.items.len);
        self.items[index] = value;
        self.count += 1;
    }

    pub fn removeGlobal(self: *OutputStorage, global_name: u32) ?output.Output {
        for (self.retainedMut(), 0..) |value, index| {
            if (value.global_name != global_name) continue;
            const removed = value;
            self.count -= 1;
            if (index != self.count) self.items[index] = self.items[self.count];
            return removed;
        }
        return null;
    }
};

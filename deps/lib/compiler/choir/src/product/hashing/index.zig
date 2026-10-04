const std = @import("std");
const ir = @import("../../core/root.zig");
const hashing = @import("root.zig");
const capacity = hashing.capacity;
const walk = hashing.walk;

const Allocator = std.mem.Allocator;

pub const ValueIndex = struct {
    entries: []capacity.ValueEntry,

    pub fn init(allocator: Allocator, derived: capacity.Capacity) Allocator.Error!ValueIndex {
        return .{
            .entries = try allocator.alloc(capacity.ValueEntry, derived.facts.value_count),
        };
    }

    pub fn deinit(self: *ValueIndex, allocator: Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn fill(
        self: *ValueIndex,
        root: *ir.Operation,
        frames: []capacity.OperationFrame,
    ) error{ InputChanged, DuplicateValueDefinition }!void {
        var iterator = walk.Iterator.init(frames, root);
        var count: usize = 0;
        while (iterator.next()) |event| switch (event) {
            .operation => |operation| {
                for (operation.results.items) |*result| {
                    try self.append(result, &count);
                }
            },
            .region => {},
            .block => |block| {
                for (block.arguments.items) |argument| {
                    try self.append(argument, &count);
                }
            },
        };
        if (count != self.entries.len) return error.InputChanged;
        std.sort.heap(capacity.ValueEntry, self.entries, {}, lessThanEntry);
        if (self.entries.len > 1) {
            for (self.entries[1..], self.entries[0 .. self.entries.len - 1]) |current, previous| {
                if (current.value == previous.value) return error.DuplicateValueDefinition;
            }
        }
    }

    pub fn lookup(self: *const ValueIndex, value: *const ir.Value) ?u64 {
        const address = @intFromPtr(value);
        var low: usize = 0;
        var high = self.entries.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const candidate = self.entries[mid];
            const candidate_address = @intFromPtr(candidate.value);
            if (candidate_address < address) {
                low = mid + 1;
            } else if (candidate_address > address) {
                high = mid;
            } else {
                return candidate.id;
            }
        }
        return null;
    }

    pub fn matchesDefinitions(
        self: *const ValueIndex,
        root: *ir.Operation,
        frames: []capacity.OperationFrame,
    ) bool {
        var iterator = walk.Iterator.init(frames, root);
        var count: u64 = 0;
        while (iterator.next()) |event| switch (event) {
            .operation => |operation| {
                for (operation.results.items) |*result| {
                    if (!self.matches(result, count)) return false;
                    count += 1;
                }
            },
            .region => {},
            .block => |block| {
                for (block.arguments.items) |argument| {
                    if (!self.matches(argument, count)) return false;
                    count += 1;
                }
            },
        };
        return count == self.entries.len;
    }

    fn append(
        self: *ValueIndex,
        value: *const ir.Value,
        count: *usize,
    ) error{InputChanged}!void {
        if (count.* >= self.entries.len) return error.InputChanged;
        self.entries[count.*] = .{ .value = value, .id = @intCast(count.*) };
        count.* += 1;
    }

    fn matches(self: *const ValueIndex, value: *const ir.Value, id: u64) bool {
        return self.lookup(value) == id;
    }
};

fn lessThanEntry(_: void, lhs: capacity.ValueEntry, rhs: capacity.ValueEntry) bool {
    return @intFromPtr(lhs.value) < @intFromPtr(rhs.value);
}

const std = @import("std");
const pointer_cache = @import("../../cache/root.zig");
const class_policy = @import("class.zig");
const model = @import("../root.zig").model;

const Allocator = std.mem.Allocator;
const Bin = pointer_cache.PointerBin(model.bin_capacity);
const Class = model.Class;
const Entry = model.Entry;

pub const Cache = struct {
    bins: [model.medium_class_count]Bin = @as([model.medium_class_count]Bin, @splat(.{})),
    cached_bytes: usize = 0,
    eviction_cursor: usize = 0,

    pub fn pop(self: *Cache, class: Class) ?[*]u8 {
        const ptr = self.bins[class.index].pop() orelse return null;
        self.cached_bytes -= class.size;
        return ptr;
    }

    pub fn popAtLeast(self: *Cache, class: Class) ?Entry {
        var index = class.index;
        while (index < self.bins.len) : (index += 1) {
            const cached_class = class_policy.classForIndex(index);
            const ptr = self.pop(cached_class) orelse continue;
            return .{ .class = cached_class, .ptr = ptr };
        }
        return null;
    }

    pub fn push(
        self: *Cache,
        class: Class,
        ptr: [*]u8,
        byte_limit: usize,
        allocator: Allocator,
        ret_addr: usize,
    ) bool {
        if (class.size > byte_limit) return false;
        if (self.bins[class.index].count >= model.bin_capacity) return false;
        while (self.cached_bytes + class.size > byte_limit) {
            if (!self.evictOne(allocator, ret_addr)) return false;
        }
        if (!self.bins[class.index].push(ptr, model.bin_capacity)) return false;
        self.cached_bytes += class.size;
        return true;
    }

    pub fn destroyAll(self: *Cache, allocator: Allocator, ret_addr: usize) void {
        for (&self.bins, 0..) |*bin, index| {
            const class_size = class_policy.sizeForIndex(index);
            while (bin.pop()) |ptr| {
                allocator.rawFree(
                    ptr[0..class_policy.backingSizeForClassSize(class_size)],
                    model.alignment,
                    ret_addr,
                );
            }
        }
        self.cached_bytes = 0;
        self.eviction_cursor = 0;
    }

    fn evictOne(self: *Cache, allocator: Allocator, ret_addr: usize) bool {
        var offset: usize = 0;
        while (offset < self.bins.len) : (offset += 1) {
            const index = (self.eviction_cursor + offset) % self.bins.len;
            const class_size = class_policy.sizeForIndex(index);
            const ptr = self.bins[index].pop() orelse continue;
            self.cached_bytes -= class_size;
            self.eviction_cursor = (index + 1) % self.bins.len;
            allocator.rawFree(
                ptr[0..class_policy.backingSizeForClassSize(class_size)],
                model.alignment,
                ret_addr,
            );
            return true;
        }
        return false;
    }
};

test "medium cache reuses medium classes" {
    var cache_state: Cache = .{};
    const allocator = std.testing.allocator;
    const class = class_policy.classFor(400 * 1024, .@"1").?;
    defer cache_state.destroyAll(allocator, @returnAddress());

    const memory = allocator.rawAlloc(
        class_policy.backingSize(class),
        model.alignment,
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    try std.testing.expect(cache_state.push(
        class,
        memory,
        class.size,
        allocator,
        @returnAddress(),
    ));

    const reused = cache_state.popAtLeast(class) orelse return error.MissingCachedBlock;
    try std.testing.expectEqual(@intFromPtr(memory), @intFromPtr(reused.ptr));
    allocator.rawFree(reused.ptr[0..class_policy.backingSize(reused.class)], model.alignment, @returnAddress());
}

test "medium cache can reuse a larger medium class" {
    var cache_state: Cache = .{};
    const allocator = std.testing.allocator;
    const smaller = class_policy.classFor(320 * 1024, .@"1").?;
    const larger = class_policy.classFor(400 * 1024, .@"1").?;
    defer cache_state.destroyAll(allocator, @returnAddress());

    const memory = allocator.rawAlloc(
        class_policy.backingSize(larger),
        model.alignment,
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    try std.testing.expect(cache_state.push(
        larger,
        memory,
        larger.size,
        allocator,
        @returnAddress(),
    ));

    const reused = cache_state.popAtLeast(smaller) orelse return error.MissingCachedBlock;
    try std.testing.expectEqual(larger.index, reused.class.index);
    try std.testing.expectEqual(@intFromPtr(memory), @intFromPtr(reused.ptr));
    allocator.rawFree(reused.ptr[0..class_policy.backingSize(reused.class)], model.alignment, @returnAddress());
}

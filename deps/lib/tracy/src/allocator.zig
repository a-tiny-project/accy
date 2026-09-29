const std = @import("std");
const runtime = @import("runtime.zig");

pub const Options = struct {
    name: []const u8 = "tracy.allocator",
};

pub const TracedAllocator = struct {
    backing: std.mem.Allocator,
    name: []const u8,

    pub fn init(backing: std.mem.Allocator, options: Options) TracedAllocator {
        return .{
            .backing = backing,
            .name = options.name,
        };
    }

    pub fn allocator(self: *TracedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    fn rawAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TracedAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        runtime.allocAddress(addressOf(ptr), len, self.name);
        return ptr;
    }

    fn rawResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TracedAllocator = @ptrCast(@alignCast(ctx));
        const resized = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (resized) self.recordResize(memory.ptr, memory.len, new_len);
        return resized;
    }

    fn rawRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TracedAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        runtime.freeAddress(addressOf(memory.ptr), memory.len, self.name);
        if (new_len != 0) runtime.allocAddress(addressOf(ptr), new_len, self.name);
        return ptr;
    }

    fn rawFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TracedAllocator = @ptrCast(@alignCast(ctx));
        runtime.freeAddress(addressOf(memory.ptr), memory.len, self.name);
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    fn recordResize(self: *TracedAllocator, ptr: [*]u8, old_len: usize, new_len: usize) void {
        if (old_len == new_len) return;
        runtime.freeAddress(addressOf(ptr), old_len, self.name);
        if (new_len != 0) runtime.allocAddress(addressOf(ptr), new_len, self.name);
    }
};

pub fn trace(backing: std.mem.Allocator) TracedAllocator {
    return .init(backing, .{});
}

pub fn traceNamed(backing: std.mem.Allocator, name: []const u8) TracedAllocator {
    return .init(backing, .{ .name = name });
}

fn addressOf(ptr: [*]u8) u64 {
    return @intCast(@intFromPtr(ptr));
}

test "traced allocator records allocation pressure" {
    if (!runtime.enabled) return;

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expect(try runtime.start(&out.writer, .{ .name = "allocator test" }));
    defer runtime.stop();
    var traced = traceNamed(std.testing.allocator, "test.alloc");
    const allocator = traced.allocator();
    const bytes = try allocator.alloc(u8, 64);
    allocator.free(bytes);
    runtime.stop();

    const memory = @import("memory.zig");
    var analyzer = memory.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(out.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.allocations);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.frees);
    try std.testing.expectEqual(@as(u64, 64), analyzer.counters.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 64), analyzer.counters.freed_bytes);
    try std.testing.expectEqual(@as(u64, 0), analyzer.counters.live_bytes);
}

test "traced allocator records resize as free and alloc" {
    if (!runtime.enabled) return;

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expect(try runtime.start(&out.writer, .{ .name = "allocator resize test" }));
    defer runtime.stop();
    var traced = traceNamed(std.testing.allocator, "test.resize");
    const allocator = traced.allocator();
    var bytes = try allocator.alloc(u8, 32);
    bytes = try allocator.realloc(bytes, 96);
    allocator.free(bytes);
    runtime.stop();

    const memory = @import("memory.zig");
    var analyzer = memory.Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(out.written());
    try std.testing.expect(analyzer.counters.allocations >= 2);
    try std.testing.expect(analyzer.counters.frees >= 2);
    try std.testing.expectEqual(@as(u64, 0), analyzer.counters.live_bytes);
}

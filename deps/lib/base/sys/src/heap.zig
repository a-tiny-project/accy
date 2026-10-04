const std = @import("std");
const capabilities = @import("capabilities.zig");
const memory = @import("memory.zig");

pub const required_capabilities = capabilities.noLibc(&.{.memory_mapping});

const malloc_alignment = 16;
const header_size = 32;
const magic: u64 = 0x5153_5953_4845_4150;

const Header = extern struct {
    magic: u64,
    mapped_len: usize,
    payload_len: usize,
};

comptime {
    std.debug.assert(@sizeOf(Header) <= header_size);
    std.debug.assert(header_size % malloc_alignment == 0);
}

pub fn malloc(byte_count: usize) callconv(.c) ?*anyopaque {
    const payload_len = @max(byte_count, 1);
    const requested_len = std.math.add(usize, header_size, payload_len) catch return null;
    const mapping = memory.mapAnonymous(requested_len, .{ .read = true, .write = true }) catch return null;

    const header: *Header = @ptrCast(@alignCast(mapping.ptr));
    header.* = .{
        .magic = magic,
        .mapped_len = mapping.len,
        .payload_len = payload_len,
    };

    return @ptrCast(mapping.ptr + header_size);
}

pub fn calloc(count: usize, byte_count: usize) callconv(.c) ?*anyopaque {
    const total = std.math.mul(usize, count, byte_count) catch return null;
    const raw = malloc(total) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @memset(bytes[0..total], 0);
    return raw;
}

pub fn realloc(ptr: ?*anyopaque, byte_count: usize) callconv(.c) ?*anyopaque {
    const raw = ptr orelse return malloc(byte_count);
    if (byte_count == 0) {
        free(raw);
        return null;
    }

    const header = headerFromRaw(raw);
    const old_len = header.payload_len;
    const result = malloc(byte_count) orelse return null;
    const source: [*]const u8 = @ptrCast(raw);
    const target: [*]u8 = @ptrCast(result);
    const copy_len = @min(old_len, byte_count);
    @memcpy(target[0..copy_len], source[0..copy_len]);
    free(raw);
    return result;
}

pub fn free(ptr: ?*anyopaque) callconv(.c) void {
    const raw = ptr orelse return;
    const header = headerFromRaw(raw);

    const mapped_len = header.mapped_len;
    header.magic = 0;
    const user: [*]u8 = @ptrCast(raw);
    const base = user - header_size;
    const mapping: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(base));
    memory.unmap(mapping[0..mapped_len]);
}

pub fn freeAddress(address: usize) void {
    free(@ptrFromInt(address));
}

fn headerFromRaw(raw: *anyopaque) *Header {
    const user: [*]u8 = @ptrCast(raw);
    const base = user - header_size;
    const header: *Header = @ptrCast(@alignCast(base));
    if (header.magic != magic) @trap();
    return header;
}

test "malloc returns aligned memory and free accepts null" {
    const ptr = malloc(33) orelse return error.OutOfMemory;
    try std.testing.expect(std.mem.isAligned(@intFromPtr(ptr), malloc_alignment));
    free(ptr);
    free(null);
}

test "calloc zeros memory and realloc preserves prefix" {
    const raw = calloc(4, 2) orelse return error.OutOfMemory;
    const bytes: [*]u8 = @ptrCast(raw);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), bytes[0..8]);
    bytes[0] = 1;
    bytes[7] = 2;

    const grown = realloc(raw, 16) orelse return error.OutOfMemory;
    const grown_bytes: [*]u8 = @ptrCast(grown);
    try std.testing.expectEqual(@as(u8, 1), grown_bytes[0]);
    try std.testing.expectEqual(@as(u8, 2), grown_bytes[7]);

    const shrunk = realloc(grown, 1) orelse return error.OutOfMemory;
    const shrunk_bytes: [*]u8 = @ptrCast(shrunk);
    try std.testing.expectEqual(@as(u8, 1), shrunk_bytes[0]);
    try std.testing.expectEqual(@as(?*anyopaque, null), realloc(shrunk, 0));
}

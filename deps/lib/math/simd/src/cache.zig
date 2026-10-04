const std = @import("std");
const builtin = @import("builtin");
const aligned = @import("aligned.zig");

pub const stream_multiple: usize = 16;
pub const words_per_line: usize = aligned.alignment / @sizeOf(u64);

pub inline fn loadFence() void {
    switch (comptime builtin.target.cpu.arch) {
        .x86, .x86_64 => asm volatile ("lfence" ::: .{ .memory = true }),
        else => {},
    }
}

pub fn streamCacheLine(
    source: *const [words_per_line]u64,
    destination: *[words_per_line]u64,
) void {
    std.debug.assert(aligned.isAligned(source));
    std.debug.assert(aligned.isAligned(destination));
    std.debug.assert(@intFromPtr(source) != @intFromPtr(destination));
    destination.* = source.*;
}

pub inline fn flushStream() void {
    switch (comptime builtin.target.cpu.arch) {
        .x86, .x86_64 => asm volatile ("sfence" ::: .{ .memory = true }),
        else => {},
    }
}

pub inline fn prefetch(pointer: anytype) void {
    @prefetch(pointer, .{});
}

pub inline fn flushCacheline(pointer: *const anyopaque) void {
    switch (comptime builtin.target.cpu.arch) {
        .x86_64 => asm volatile ("clflush (%%rax)"
            :
            : [address] "{rax}" (pointer),
            : .{ .memory = true }),
        .x86 => asm volatile ("clflush (%%eax)"
            :
            : [address] "{eax}" (pointer),
            : .{ .memory = true }),
        else => {},
    }
}

pub inline fn pause() void {
    switch (comptime builtin.target.cpu.arch) {
        .x86, .x86_64 => asm volatile ("pause"),
        .aarch64, .aarch64_be, .arm, .armeb, .thumb, .thumbeb => asm volatile ("yield"),
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => asm volatile ("or 27, 27, 27"),
        else => {},
    }
}

test "Highway streamed cache line copies exactly one aligned line" {
    try std.testing.expectEqual(@as(usize, 128), aligned.alignment);
    try std.testing.expectEqual(@as(usize, 16), stream_multiple);
    var source: [words_per_line]u64 align(aligned.alignment) = undefined;
    for (&source, 0..) |*value, index| {
        value.* = 0x0102_0304_0506_0708 + @as(u64, @intCast(index));
    }
    var blocks: [3][words_per_line]u64 align(aligned.alignment) = @splat(@splat(0xa5a5_a5a5_a5a5_a5a5));
    streamCacheLine(&source, &blocks[1]);
    flushStream();
    try std.testing.expectEqualSlices(u64, &source, &blocks[1]);
    var digest: u64 = 0;
    for (blocks[1]) |value| digest +%= value;
    try std.testing.expectEqual(@as(u64, 0x1020_3040_5060_70f8), digest);
    try std.testing.expectEqualSlices(
        u64,
        &@as([words_per_line]u64, @splat(0xa5a5_a5a5_a5a5_a5a5)),
        &blocks[0],
    );
    try std.testing.expectEqualSlices(
        u64,
        &@as([words_per_line]u64, @splat(0xa5a5_a5a5_a5a5_a5a5)),
        &blocks[2],
    );
}

test "Highway cache controls preserve accessible values" {
    var value: u64 align(aligned.alignment) = 42;
    loadFence();
    prefetch(&value);
    flushCacheline(&value);
    pause();
    try std.testing.expectEqual(@as(u64, 42), value);
}

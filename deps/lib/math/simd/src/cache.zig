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

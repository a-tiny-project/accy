const std = @import("std");
const target = @import("../target/root.zig");

pub fn requireNativeCpuArtifacts() !void {
    if (comptime !target.native_cpu_artifacts_supported) return error.SkipZigTest;
}

pub fn checkAllAllocationFailures(comptime test_fn: anytype, extra_args: anytype) !void {
    var backing_allocator: std.heap.DebugAllocator(.{
        .stack_trace_frames = 0,
    }) = .init;
    defer std.testing.expect(backing_allocator.deinit() == .ok) catch @panic("backing allocator leaked");
    try std.testing.checkAllAllocationFailures(
        backing_allocator.allocator(),
        test_fn,
        extra_args,
    );
}

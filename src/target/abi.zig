const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");

pub fn argumentCount(format: gpu.ArtifactFormat, count: u32) gpu.BackendError!u32 {
    if (!gpu.artifactFormatUsesHostLoopLaunch(format)) return count;
    return gpu_abi.kernelArgumentCount(count);
}

pub fn launchGeometry(
    format: gpu.ArtifactFormat,
    element_count: u64,
    geometry: ?gpu_abi.LaunchGeometry,
) gpu.BackendError!?gpu_abi.LaunchGeometry {
    if (!gpu.artifactFormatUsesHostLoopLaunch(format)) return geometry;
    if (geometry) |value| return value;
    const count = std.math.cast(u32, @max(element_count, 1)) orelse
        return error.LaunchArgumentMismatch;
    return .{ .grid = .{ count, 1, 1 }, .threadgroup = .{ 1, 1, 1 } };
}

pub fn staticArguments(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    element_count: u64,
    geometry: ?gpu_abi.LaunchGeometry,
) gpu.BackendError![]gpu_abi.ScalarArgument {
    if (!gpu.artifactFormatUsesHostLoopLaunch(format)) return &.{};
    return gpu_abi.launchShapeArguments(
        allocator,
        element_count,
        (try launchGeometry(format, element_count, geometry)).?,
    );
}

test "target ABI preserves host loop and device launch contracts" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 3), try argumentCount(.cuda_ptx, 3));
    try std.testing.expectEqual(@as(u32, 3 + gpu_abi.launch_shape_argument_count), try argumentCount(.cpu_object, 3));
    const arguments = try staticArguments(allocator, .cpu_object, 5, null);
    defer allocator.free(arguments);
    const expected = [_]u32{ 0, 5, 5, 1, 1, 1, 1, 1 };
    try std.testing.expectEqual(expected.len, arguments.len);
    for (arguments, expected) |argument, value| try std.testing.expectEqual(value, argument.u32);
    const device = try staticArguments(allocator, .cuda_ptx, 5, null);
    defer allocator.free(device);
    try std.testing.expectEqual(@as(usize, 0), device.len);
    try std.testing.expectEqual(null, try launchGeometry(.cuda_ptx, 5, null));
    try std.testing.expectError(error.InvalidArtifact, argumentCount(
        .cpu_object,
        std.math.maxInt(u32),
    ));
    try std.testing.expectError(error.LaunchArgumentMismatch, launchGeometry(
        .cpu_object,
        std.math.maxInt(u64),
        null,
    ));
}

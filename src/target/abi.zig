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

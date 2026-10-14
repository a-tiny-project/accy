const std = @import("std");

const gating = @import("gpu_gating");
const driver = @import("sys").cuda;
const runtime = @import("runtime.zig");

pub fn requireEnabled() error{SkipZigTest}!void {
    try gating.skipIfBuildFlagDisabled(.cuda);
}

pub fn initRuntimeOrSkip(
    allocator: std.mem.Allocator,
    device_ordinal: i32,
) (driver.Error || error{SkipZigTest})!runtime.Runtime {
    try requireEnabled();
    if (!driver.platformSupported()) return gating.skip(.cuda, .unsupported_platform);

    return runtime.Runtime.init(allocator, device_ordinal) catch |err| switch (err) {
        error.CudaDriverNotFound => return gating.skip(.cuda, .cuda_driver_missing),
        error.CudaNoDevice,
        error.CudaInvalidDevice,
        => return gating.skip(.cuda, .cuda_device_missing),
        else => return err,
    };
}

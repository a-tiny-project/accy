const std = @import("std");

const gating = @import("gpu_gating");

pub const max_kernel_arguments: usize = 32;

pub const ScalarArgumentTag = enum {
    i32,
    u32,
    i64,
    u64,
    f32,
    f64,
};

pub const ScalarArgument = struct {
    tag: ScalarArgumentTag,
    bits: u64,

    pub fn byteSize(self: ScalarArgument) usize {
        return switch (self.tag) {
            .i32, .u32, .f32 => 4,
            .i64, .u64, .f64 => 8,
        };
    }
};

pub const Error = error{
    UnsupportedPlatform,
    RuntimeUnavailable,
    DeviceUnavailable,
    CompilationFailed,
    LaunchFailed,
    ResultMismatch,
    DeviceLost,
    InvalidArtifact,
    InvalidBuffer,
    InvalidStream,
    InvalidEvent,
    OutOfMemory,
    /// The Cocoa layer a surface needs is missing, or a Metal layer cannot attach to it.
    SurfaceUnavailable,
    /// No drawable freed up within the layer's timeout.
    FrameUnavailable,
};

pub const Availability = enum {
    available,
    unsupported_platform,
    runtime_missing,
    device_missing,
};

pub const SmokeFailure = enum {
    unsupported_platform,
    runtime_missing,
    device_missing,
    compile_failed,
    launch_failed,
    result_mismatch,
};

pub fn smokeFailureForInitError(err: Error) SmokeFailure {
    return switch (err) {
        error.UnsupportedPlatform => .unsupported_platform,
        error.RuntimeUnavailable => .runtime_missing,
        error.DeviceUnavailable => .device_missing,
        else => .runtime_missing,
    };
}

pub fn smokeFailureForCompileError(err: Error) SmokeFailure {
    return switch (err) {
        error.CompilationFailed,
        error.InvalidArtifact,
        => .compile_failed,
        error.RuntimeUnavailable => .runtime_missing,
        error.DeviceUnavailable => .device_missing,
        error.UnsupportedPlatform => .unsupported_platform,
        else => .compile_failed,
    };
}

pub fn smokeFailureForLaunchError(err: Error) SmokeFailure {
    return switch (err) {
        error.LaunchFailed,
        error.InvalidBuffer,
        error.DeviceLost,
        => .launch_failed,
        error.RuntimeUnavailable => .runtime_missing,
        error.DeviceUnavailable => .device_missing,
        error.UnsupportedPlatform => .unsupported_platform,
        else => .launch_failed,
    };
}

pub fn smokeFailureLabel(failure: SmokeFailure) []const u8 {
    return switch (failure) {
        .unsupported_platform => "unsupported platform",
        .runtime_missing => "Metal runtime missing",
        .device_missing => "Metal device missing",
        .compile_failed => "Metal compile failed",
        .launch_failed => "Metal launch failed",
        .result_mismatch => "Metal result mismatch",
    };
}

pub fn skipReasonForSmokeFailure(failure: SmokeFailure) ?gating.SkipReason {
    return switch (failure) {
        .unsupported_platform => .unsupported_platform,
        .runtime_missing => .metal_runtime_missing,
        .device_missing => .metal_device_missing,
        .compile_failed,
        .launch_failed,
        .result_mismatch,
        => null,
    };
}

test "metal runtime smoke failures have stable labels and skip mapping" {
    try std.testing.expectEqual(SmokeFailure.unsupported_platform, smokeFailureForInitError(error.UnsupportedPlatform));
    try std.testing.expectEqual(SmokeFailure.runtime_missing, smokeFailureForInitError(error.RuntimeUnavailable));
    try std.testing.expectEqual(SmokeFailure.device_missing, smokeFailureForInitError(error.DeviceUnavailable));
    try std.testing.expectEqual(SmokeFailure.compile_failed, smokeFailureForCompileError(error.CompilationFailed));
    try std.testing.expectEqual(SmokeFailure.launch_failed, smokeFailureForLaunchError(error.LaunchFailed));

    try std.testing.expectEqualStrings("Metal compile failed", smokeFailureLabel(.compile_failed));
    try std.testing.expectEqual(gating.SkipReason.unsupported_platform, skipReasonForSmokeFailure(.unsupported_platform).?);
    try std.testing.expectEqual(gating.SkipReason.metal_runtime_missing, skipReasonForSmokeFailure(.runtime_missing).?);
    try std.testing.expectEqual(gating.SkipReason.metal_device_missing, skipReasonForSmokeFailure(.device_missing).?);
    try std.testing.expect(skipReasonForSmokeFailure(.compile_failed) == null);
    try std.testing.expect(skipReasonForSmokeFailure(.launch_failed) == null);
    try std.testing.expect(skipReasonForSmokeFailure(.result_mismatch) == null);
}

test "Metal scalar arguments preserve exact source widths" {
    try std.testing.expectEqual(@as(usize, 4), (ScalarArgument{ .tag = .i32, .bits = 0 }).byteSize());
    try std.testing.expectEqual(@as(usize, 4), (ScalarArgument{ .tag = .f32, .bits = 0 }).byteSize());
    try std.testing.expectEqual(@as(usize, 8), (ScalarArgument{ .tag = .u64, .bits = 0 }).byteSize());
    try std.testing.expectEqual(@as(usize, 8), (ScalarArgument{ .tag = .f64, .bits = 0 }).byteSize());
}

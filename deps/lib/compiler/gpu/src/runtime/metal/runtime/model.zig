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

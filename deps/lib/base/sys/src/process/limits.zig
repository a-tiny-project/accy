//! Per-process descriptor limits.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const control = @import("control.zig");

/// Windows, WASI and freestanding targets have no per-process descriptor limit.
const has_descriptor_limit = switch (builtin.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};

const is_darwin = switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
    else => false,
};

pub const DescriptorLimits = struct {
    soft: u64,
    hard: u64,
    /// The largest soft limit this process may set. Darwin refuses a soft limit
    /// above `kern.maxfilesperproc`, so there it is the smaller of that and
    /// `hard`. Root may go up to `kern.maxfiles`, so this bound is conservative
    /// for root. Other platforms bound the soft limit by `hard` alone.
    ceiling: u64,
};

pub const DescriptorLimitError = error{
    UnsupportedPlatform,
    CeilingUnavailable,
    LimitTooBig,
    PermissionDenied,
    Unexpected,
};

pub fn descriptorLimits() DescriptorLimitError!DescriptorLimits {
    if (comptime !has_descriptor_limit) return error.UnsupportedPlatform;
    const limits = try posix.getrlimit(.NOFILE);
    return .{
        .soft = limits.cur,
        .hard = limits.max,
        .ceiling = @min(limits.max, try perProcessMaximum()),
    };
}

/// Sets the soft descriptor limit and keeps the hard limit. A soft limit at or
/// below `ceiling` needs no privilege, and children inherit it.
pub fn setDescriptorSoftLimit(soft: u64) DescriptorLimitError!void {
    if (comptime !has_descriptor_limit) return error.UnsupportedPlatform;
    const limits = try descriptorLimits();
    if (soft > limits.ceiling) return error.LimitTooBig;
    try posix.setrlimit(.NOFILE, .{ .cur = soft, .max = limits.hard });
}

fn perProcessMaximum() DescriptorLimitError!u64 {
    if (comptime !is_darwin) return std.math.maxInt(u64);
    var value: c_int = 0;
    const size = control.systemControl("kern.maxfilesperproc", &value) catch
        return error.CeilingUnavailable;
    if (size != @sizeOf(c_int) or value <= 0) return error.CeilingUnavailable;
    return @intCast(value);
}

test "descriptor soft limit moves within the ceiling" {
    if (comptime !has_descriptor_limit) return error.SkipZigTest;
    const saved = try descriptorLimits();
    try std.testing.expect(saved.ceiling <= saved.hard);
    if (saved.ceiling < 257) return error.SkipZigTest;
    defer posix.setrlimit(.NOFILE, .{ .cur = saved.soft, .max = saved.hard }) catch unreachable;

    try setDescriptorSoftLimit(256);
    try std.testing.expectEqual(
        DescriptorLimits{ .soft = 256, .hard = saved.hard, .ceiling = saved.ceiling },
        try descriptorLimits(),
    );
    try setDescriptorSoftLimit(257);
    try std.testing.expectEqual(@as(u64, 257), (try descriptorLimits()).soft);
    if (saved.ceiling != std.math.maxInt(u64)) {
        try std.testing.expectError(error.LimitTooBig, setDescriptorSoftLimit(saved.ceiling + 1));
    }
}

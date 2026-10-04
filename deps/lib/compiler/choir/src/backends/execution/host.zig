//! Which target, if any, executes code on a host.

const std = @import("std");
const sys = @import("sys");
const runtime = @import("runtime.zig");
const target = @import("target.zig");

const Capabilities = sys.capabilities.Capabilities;

/// Why `profile` has no execution target, or null when it has one. x86_64 executes on Linux
/// only: the target implements the System V convention, and Linux is the only system it has run
/// on. aarch64 executes only on a qualified macOS arm64 host.
pub fn reason(comptime profile: Capabilities) ?[]const u8 {
    return comptime switch (profile.arch) {
        .x86_64 => if (profile.os == .windows)
            "x86_64 execution follows the System V convention, " ++
                "and Windows uses the Microsoft x64 convention"
        else if (profile.os != .linux)
            "x86_64 execution is admitted on Linux only, and " ++
                @tagName(profile.os) ++ " has no witness"
        else if (profile.pointerWidthBits() != 64)
            "x86_64 execution needs 64-bit pointers, and the " ++
                @tagName(profile.abi) ++ " ABI has " ++
                std.fmt.comptimePrint("{d}", .{profile.pointerWidthBits()})
        else
            null,
        .aarch64 => if (profile.os != .macos)
            "aarch64 execution is admitted on macOS only, and " ++
                @tagName(profile.os) ++ " has no witness"
        else if (profile.pointerWidthBits() != 64)
            "aarch64 execution needs 64-bit pointers"
        else
            null,
        else => "no execution target exists for " ++ @tagName(profile.arch),
    };
}

/// The target that executes on `profile`, or `target.Unavailable` carrying `reason(profile)`.
pub fn Select(comptime profile: Capabilities) type {
    if (reason(profile)) |why| return target.Unavailable(why);
    return switch (profile.arch) {
        .x86_64 => @import("../x64/execution.zig").Target,
        .aarch64 => @import("../aarch64/execution.zig").Target,
        else => unreachable,
    };
}

/// Execution on the host this build runs on. Ordinary consumers use only a default-qualified
/// product. An Apple scalar target exists, but its product must opt in explicitly after
/// inspection; the ordinary runtime remains unavailable and names that reason.
pub const native = struct {
    pub const Target: type = Select(sys.capabilities.current);
    pub const Runtime: type = runtime.Runtime(Target);
    pub const available: bool = Runtime.available;
    pub const reason: ?[]const u8 = if (Target.unavailable) |why|
        why
    else if (!available)
        "native execution requires an explicit qualified executable product policy"
    else
        null;
};

test "the selector admits Linux x86_64 and macOS aarch64 by name" {
    const testing = std.testing;
    const none: ?[]const u8 = null;
    try testing.expectEqual(
        none,
        comptime reason(.{ .os = .linux, .arch = .x86_64, .abi = .gnu }),
    );
    try testing.expectEqual(
        none,
        comptime reason(.{ .os = .linux, .arch = .x86_64, .abi = .musl }),
    );
    try testing.expectEqualStrings(
        "x86_64 execution follows the System V convention, " ++
            "and Windows uses the Microsoft x64 convention",
        comptime reason(.{ .os = .windows, .arch = .x86_64, .abi = .msvc }).?,
    );
    try testing.expectEqualStrings(
        "x86_64 execution is admitted on Linux only, and macos has no witness",
        comptime reason(.{ .os = .macos, .arch = .x86_64 }).?,
    );
    try testing.expectEqualStrings(
        "x86_64 execution needs 64-bit pointers, and the gnux32 ABI has 32",
        comptime reason(.{ .os = .linux, .arch = .x86_64, .abi = .gnux32 }).?,
    );
    try testing.expectEqualStrings(
        "aarch64 execution is admitted on macOS only, and linux has no witness",
        comptime reason(.{ .os = .linux, .arch = .aarch64 }).?,
    );
    try testing.expectEqual(none, comptime reason(.{ .os = .macos, .arch = .aarch64 }));
    try testing.expectEqualStrings(
        "no execution target exists for wasm32",
        comptime reason(.{ .os = .freestanding, .arch = .wasm32 }).?,
    );
}

test "the native runtime advertises only a default-qualified product" {
    try std.testing.expectEqual(
        reason(sys.capabilities.current) == null and native.Runtime.default_executable_policy != .unverified,
        native.available,
    );
    try std.testing.expectEqual(native.reason == null, native.available);
    if (native.Target.architecture == .aarch64) {
        try std.testing.expect(!native.available);
        try std.testing.expectEqualStrings(
            "native execution requires an explicit qualified executable product policy",
            native.reason.?,
        );
    }
}

test "an unavailable runtime refuses init by name and allocates nothing" {
    const Refused = runtime.Runtime(target.Unavailable("no execution target exists for this test"));
    try std.testing.expect(!Refused.available);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const refused = Refused.init(failing.allocator(), .testing);
    try std.testing.expectError(error.ExecutionUnavailable, refused);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

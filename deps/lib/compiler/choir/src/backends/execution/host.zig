//! Which target, if any, executes code on a host.

const std = @import("std");
const sys = @import("sys");
const runtime = @import("runtime.zig");
const target = @import("target.zig");

const Capabilities = sys.capabilities.Capabilities;

/// Why `profile` has no execution target, or null when it has one. x86_64 executes on Linux and
/// macOS, the two systems whose System V code it has run: Linux natively, and macOS under
/// Rosetta 2 on an arm64 Mac, which leaves native x86_64 Mac hardware unwitnessed. aarch64
/// executes only on a qualified macOS arm64 host.
pub fn reason(comptime profile: Capabilities) ?[]const u8 {
    return comptime switch (profile.arch) {
        .x86_64 => if (profile.os == .windows)
            "x86_64 execution follows the System V convention, " ++
                "and Windows uses the Microsoft x64 convention"
        else if (profile.os != .linux and profile.os != .macos)
            "x86_64 execution is admitted on Linux and macOS only, and " ++
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

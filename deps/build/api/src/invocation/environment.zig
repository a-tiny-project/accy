const std = @import("std");

pub const Value = struct {
    name: []const u8,
    value: ?[]const u8,
};

const Class = enum { input, administrative };

/// Every environment variable declared by the pinned compiler is classified.
/// Path selection is retained even for derived caches: generated source paths
/// can be observed by compiler code. Terminal and diagnostic output is separate.
fn classify(value: std.zig.EnvVar) Class {
    return switch (value) {
        .ZIG_LIB_DIR,
        .ZIG_LIBC,
        .ZIG_IS_DETECTING_LIBC_PATHS,
        .ZIG_IS_AVOIDING_CALLING_ITSELF,
        .NIX_CFLAGS_COMPILE,
        .NIX_CFLAGS_LINK,
        .NIX_LDFLAGS,
        .C_INCLUDE_PATH,
        .CPLUS_INCLUDE_PATH,
        .LIBRARY_PATH,
        .CC,
        .PKG_CONFIG,
        .PROGRAMDATA,
        .HOMEBREW_PREFIX,
        .ZIG_GLOBAL_CACHE_DIR,
        .ZIG_LOCAL_CACHE_DIR,
        .ZIG_LOCAL_PKG_DIR,
        .XDG_CACHE_HOME,
        .LOCALAPPDATA,
        .HOME,
        => .input,
        .ZIG_BUILD_ERROR_STYLE,
        .ZIG_BUILD_MULTILINE_ERRORS,
        .ZIG_BUILD_SUMMARY,
        .ZIG_VERBOSE_LINK,
        .ZIG_VERBOSE_CC,
        .ZIG_VERBOSE_CMD,
        .ZIG_DEBUG_CMD,
        .NO_COLOR,
        .CLICOLOR_FORCE,
        => .administrative,
    };
}

/// PATH can select native foreign tools. The analysis compiler's observer
/// variables are recorded too, even though ordinary launches leave them absent.
const additional = [_][]const u8{
    "PATH",
    "TINY_STARDUST_BUILD_PLUGIN",
    "TINY_STARDUST_BUILD_SESSION_DIR",
    "TINY_STARDUST_REGISTERED_ROOT",
    "TINY_STARDUST_REPOSITORY_ROOT",
};

pub fn capture(
    allocator: std.mem.Allocator,
    values: *const std.process.Environ.Map,
) ![]const Value {
    var result: std.ArrayList(Value) = .empty;
    inline for (@typeInfo(std.zig.EnvVar).@"enum".field_names) |name| {
        if (comptime classify(@field(std.zig.EnvVar, name)) == .input) {
            try result.append(allocator, .{ .name = name, .value = values.get(name) });
        }
    }
    for (additional) |name| {
        try result.append(allocator, .{ .name = name, .value = values.get(name) });
    }
    return result.toOwnedSlice(allocator);
}

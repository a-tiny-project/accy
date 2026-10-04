const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");

threadlocal var local_errno: c_int = 0;

pub const required_capabilities = capabilities.noLibc(&.{.libc_interop});

pub const StoragePolicy = enum {
    local_thread,
    libc_thread,
};

const LibcErrno = switch (builtin.os.tag) {
    .linux => switch (builtin.abi) {
        .android, .androideabi => Function("__errno", "c"),
        else => Function("__errno_location", "c"),
    },
    .emscripten, .serenity => Function("__errno_location", "c"),
    .wasi, .dragonfly => ThreadLocal,
    .windows => Function("_errno", "c"),
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .freebsd => Function("__error", "c"),
    .illumos => Function("___errno", "c"),
    .openbsd, .netbsd => Function("__errno", "c"),
    .haiku => Function("_errnop", "root"),
    else => Local,
};

pub fn set(value: c_int) void {
    localStorage().* = value;
}

pub fn current() c_int {
    return localStorage().*;
}

pub fn setHostInterop(value: c_int) void {
    hostInteropStorage().* = value;
}

pub fn currentHostInterop() c_int {
    return hostInteropStorage().*;
}

pub fn storagePolicy() StoragePolicy {
    return .local_thread;
}

pub fn hostInteropStoragePolicy() StoragePolicy {
    if (comptime builtin.link_libc) return LibcErrno.storage_policy;
    return .local_thread;
}

fn localStorage() *c_int {
    return &local_errno;
}

fn hostInteropStorage() *c_int {
    if (comptime builtin.link_libc) return LibcErrno.storage();
    return localStorage();
}

fn Function(comptime name: []const u8, comptime library_name: ?[]const u8) type {
    return struct {
        const storage_policy: StoragePolicy = .libc_thread;

        fn storage() *c_int {
            return @extern(*const fn () callconv(.c) *c_int, .{
                .name = name,
                .library_name = library_name,
            })();
        }
    };
}

const ThreadLocal = struct {
    const storage_policy: StoragePolicy = .libc_thread;

    extern threadlocal var errno: c_int;

    fn storage() *c_int {
        return &errno;
    }
};

const Local = struct {
    const storage_policy: StoragePolicy = .local_thread;

    fn storage() *c_int {
        return &local_errno;
    }
};

test "errno access stores nonzero values" {
    set(123);
    try std.testing.expectEqual(@as(c_int, 123), current());
    set(0);
}

test "errno access is explicit process policy" {
    set(0);
    try std.testing.expectEqual(@as(c_int, 0), current());
    try std.testing.expectEqual(StoragePolicy.local_thread, storagePolicy());
}

test "errno host interop sharing is explicit" {
    set(0);
    setHostInterop(0);

    set(77);
    try std.testing.expectEqual(@as(c_int, 77), current());
    if (comptime builtin.link_libc) {
        try std.testing.expectEqual(@as(c_int, 0), currentHostInterop());
    } else {
        try std.testing.expectEqual(@as(c_int, 77), currentHostInterop());
    }

    setHostInterop(88);
    try std.testing.expectEqual(@as(c_int, 88), currentHostInterop());
    if (comptime builtin.link_libc and LibcErrno.storage_policy == .libc_thread) {
        try std.testing.expectEqual(@as(c_int, 77), current());
    } else {
        try std.testing.expectEqual(@as(c_int, 88), current());
    }
    const expected_policy = if (comptime builtin.link_libc) LibcErrno.storage_policy else StoragePolicy.local_thread;
    try std.testing.expectEqual(expected_policy, hostInteropStoragePolicy());

    set(0);
    setHostInterop(0);
}

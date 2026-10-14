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

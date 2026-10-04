const types = @import("types.zig");

pub fn list(storage: []types.ProcessId) types.Error![]types.ProcessId {
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn children(
    pid: types.ProcessId,
    storage: []types.ProcessId,
) types.Error![]types.ProcessId {
    _ = pid;
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn info(pid: types.ProcessId) types.Error!types.Info {
    _ = pid;
    return error.UnsupportedPlatform;
}

pub fn group(pid: types.ProcessId) types.Error!types.ProcessId {
    _ = pid;
    return error.UnsupportedPlatform;
}

pub fn exists(pid: types.ProcessId) types.Error!bool {
    _ = pid;
    return error.UnsupportedPlatform;
}

pub fn exitDescriptor(pid: types.ProcessId) types.Error!types.Descriptor {
    _ = pid;
    return error.UnsupportedPlatform;
}

pub fn name(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    _ = pid;
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn fds(
    pid: types.ProcessId,
    storage: []types.Descriptor,
) types.Error![]types.Descriptor {
    _ = pid;
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn fdFlock(pid: types.ProcessId, descriptor: types.Descriptor) types.Error!bool {
    _ = pid;
    _ = descriptor;
    return error.UnsupportedPlatform;
}

pub fn fdPath(
    pid: types.ProcessId,
    descriptor: types.Descriptor,
    storage: []u8,
) types.Error![]const u8 {
    _ = pid;
    _ = descriptor;
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn cwd(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    _ = pid;
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn command(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    _ = pid;
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn environment(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    _ = pid;
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn hostname(storage: []u8) types.Error![]const u8 {
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn pidNamespace(storage: []u8) types.Error![]const u8 {
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn cgroup(storage: []u8) types.Error![]const u8 {
    _ = storage;
    return error.UnsupportedPlatform;
}

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const proc_pid_tbsdinfo: c_int = 3;
const proc_pid_vnodepathinfo: c_int = 9;
const ctl_kern: c_int = 1;
const kern_procargs2: c_int = 49;
const process_zombie: u32 = 5;
const max_path_bytes: usize = 1024;
const rusage_info_v2: c_int = 2;

const ProcBsdInfo = extern struct {
    flags: u32,
    status: u32,
    exit_status: u32,
    pid: u32,
    parent_pid: u32,
    uid: u32,
    gid: u32,
    real_uid: u32,
    real_gid: u32,
    saved_uid: u32,
    saved_gid: u32,
    reserved: u32,
    command: [16]u8,
    name: [32]u8,
    file_count: u32,
    process_group: u32,
    job_control: u32,
    terminal_device: u32,
    terminal_group: u32,
    nice: i32,
    start_seconds: u64,
    start_microseconds: u64,
};

/// `struct rusage_info_v2` from <sys/resource.h>.
const RusageInfo = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    package_idle_wakeups: u64,
    interrupt_wakeups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    physical_footprint: u64,
    start_time: u64,
    exit_time: u64,
    child_user_time: u64,
    child_system_time: u64,
    child_package_idle_wakeups: u64,
    child_interrupt_wakeups: u64,
    child_pageins: u64,
    child_elapsed_time: u64,
    disk_bytes_read: u64,
    disk_bytes_written: u64,
};

comptime {
    std.debug.assert(@sizeOf(RusageInfo) == 160);
}

const VinfoStat = extern struct {
    device: u32,
    mode: u16,
    link_count: u16,
    inode: u64,
    uid: u32,
    gid: u32,
    access_time: i64,
    access_time_ns: i64,
    modification_time: i64,
    modification_time_ns: i64,
    change_time: i64,
    change_time_ns: i64,
    birth_time: i64,
    birth_time_ns: i64,
    size: i64,
    blocks: i64,
    block_size: i32,
    flags: u32,
    generation: u32,
    raw_device: u32,
    spare: [2]i64,
};

const VnodeInfo = extern struct {
    stat: VinfoStat,
    kind: c_int,
    padding: c_int,
    file_system: [2]i32,
};

const VnodeInfoPath = extern struct {
    info: VnodeInfo,
    path: [max_path_bytes]u8,
};

const ProcVnodePathInfo = extern struct {
    current: VnodeInfoPath,
    root: VnodeInfoPath,
};

extern "c" fn proc_listallpids(buffer: ?*anyopaque, size: c_int) c_int;
extern "c" fn proc_listchildpids(
    pid: types.ProcessId,
    buffer: ?*anyopaque,
    size: c_int,
) c_int;
extern "c" fn proc_pidinfo(
    pid: types.ProcessId,
    flavor: c_int,
    argument: u64,
    buffer: *anyopaque,
    size: c_int,
) c_int;
extern "c" fn proc_pid_rusage(pid: types.ProcessId, flavor: c_int, buffer: *RusageInfo) c_int;

const ArgumentsPart = enum {
    command,
    environment,
};

pub fn list(storage: []types.ProcessId) types.Error![]types.ProcessId {
    const byte_count = std.math.mul(usize, storage.len, @sizeOf(types.ProcessId)) catch
        return error.BufferTooSmall;
    if (byte_count > std.math.maxInt(c_int)) return error.BufferTooSmall;
    const hint = proc_listallpids(null, 0);
    if (hint < 0) return systemFailure();
    if (@as(usize, @intCast(hint)) >= storage.len) return error.BufferTooSmall;
    const count = proc_listallpids(
        @ptrCast(storage.ptr),
        @intCast(byte_count),
    );
    if (count < 0) return systemFailure();
    if (@as(usize, @intCast(count)) > storage.len) return error.InvalidData;
    return compactPids(storage[0..@intCast(count)]);
}

pub fn children(
    pid: types.ProcessId,
    storage: []types.ProcessId,
) types.Error![]types.ProcessId {
    const byte_count = std.math.mul(usize, storage.len, @sizeOf(types.ProcessId)) catch
        return error.BufferTooSmall;
    if (byte_count > std.math.maxInt(c_int)) return error.BufferTooSmall;
    if (storage.len == 0) return error.BufferTooSmall;
    std.c._errno().* = 0;
    const count = proc_listchildpids(pid, @ptrCast(storage.ptr), @intCast(byte_count));
    if (count < 0) return systemFailure();
    if (count == 0 and std.c._errno().* != 0) return systemFailure();
    if (@as(usize, @intCast(count)) >= storage.len) return error.BufferTooSmall;
    return compactPids(storage[0..@intCast(count)]);
}

pub fn info(pid: types.ProcessId) types.Error!types.Info {
    if (pid <= 0) return error.ProcessNotFound;
    const bsd = try bsdInfo(pid);
    // The physical footprint counts the process's dirty private pages,
    // compressed ones included, and leaves out clean pages it shares with
    // other processes, such as a memory-mapped file.
    var usage: RusageInfo = undefined;
    const footprint: ?u64 = if (proc_pid_rusage(pid, rusage_info_v2, &usage) == 0)
        usage.physical_footprint
    else
        null;
    return .{
        .parent_pid = @intCast(bsd.parent_pid),
        .start = .{ .darwin_time = .{
            .seconds = bsd.start_seconds,
            .microseconds = bsd.start_microseconds,
        } },
        .alive = bsd.status != process_zombie,
        .private_bytes = footprint,
    };
}

pub fn group(pid: types.ProcessId) types.Error!types.ProcessId {
    if (pid <= 0) return error.ProcessNotFound;
    var bsd: ProcBsdInfo = undefined;
    try pidInfo(pid, proc_pid_tbsdinfo, 1, &bsd);
    if (bsd.pid != pid or bsd.process_group == 0 or
        bsd.process_group > std.math.maxInt(types.ProcessId)) return error.InvalidData;
    return @intCast(bsd.process_group);
}

pub fn exists(pid: types.ProcessId) types.Error!bool {
    _ = bsdInfo(pid) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn exitDescriptor(pid: types.ProcessId) types.Error!types.Descriptor {
    _ = pid;
    return error.UnsupportedPlatform;
}

pub fn name(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    const observed = try bsdInfo(pid);
    const registered = std.mem.sliceTo(observed.name[0..], 0);
    const value = if (registered.len == 0)
        std.mem.sliceTo(observed.command[0..], 0)
    else
        registered;
    if (value.len == 0) return error.InvalidData;
    return copyText(storage, value);
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
    var paths: ProcVnodePathInfo = undefined;
    try pidInfo(pid, proc_pid_vnodepathinfo, 0, &paths);
    const value = std.mem.sliceTo(paths.current.path[0..], 0);
    if (value.len == 0) return error.InvalidData;
    return copyText(storage, value);
}

pub fn command(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    return arguments(pid, storage, .command);
}

pub fn environment(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    return arguments(pid, storage, .environment);
}

pub fn hostname(storage: []u8) types.Error![]const u8 {
    if (storage.len == 0) return error.BufferTooSmall;
    var count = storage.len;
    const rc = std.c.sysctlbyname("kern.hostname", storage.ptr, &count, null, 0);
    if (rc != 0) return systemFailure();
    if (count > storage.len) return error.BufferTooSmall;
    const value = std.mem.trim(u8, std.mem.sliceTo(storage[0..count], 0), " \t\r\n");
    return if (value.len == 0) error.InvalidData else value;
}

pub fn pidNamespace(storage: []u8) types.Error![]const u8 {
    _ = storage;
    return error.UnsupportedPlatform;
}

pub fn cgroup(storage: []u8) types.Error![]const u8 {
    _ = storage;
    return error.UnsupportedPlatform;
}

fn bsdInfo(pid: types.ProcessId) types.Error!ProcBsdInfo {
    var value: ProcBsdInfo = undefined;
    try pidInfo(pid, proc_pid_tbsdinfo, 0, &value);
    return value;
}

fn pidInfo(pid: types.ProcessId, flavor: c_int, argument: u64, output: anytype) types.Error!void {
    const output_size = @sizeOf(@TypeOf(output.*));
    if (output_size > std.math.maxInt(c_int)) return error.BufferTooSmall;
    const count = proc_pidinfo(pid, flavor, argument, output, @intCast(output_size));
    if (count == 0) return systemFailure();
    if (count != output_size) return error.InvalidData;
}

fn arguments(
    pid: types.ProcessId,
    storage: []u8,
    part: ArgumentsPart,
) types.Error![]const u8 {
    if (storage.len < @sizeOf(c_int)) return error.BufferTooSmall;
    var mib = [_]c_int{ ctl_kern, kern_procargs2, pid };
    var count = storage.len;
    const rc = std.c.sysctl(&mib, mib.len, storage.ptr, &count, null, 0);
    if (rc != 0) return systemFailure();
    if (count > storage.len) return error.BufferTooSmall;
    return selectArguments(storage[0..count], part);
}

fn selectArguments(data: []u8, part: ArgumentsPart) types.Error![]const u8 {
    if (data.len < @sizeOf(c_int)) return error.InvalidData;
    const raw_argc = std.mem.readInt(
        u32,
        data[0..@sizeOf(c_int)],
        builtin.cpu.arch.endian(),
    );
    const argc: usize = @intCast(raw_argc);
    var offset: usize = @sizeOf(c_int);
    offset = (std.mem.indexOfScalarPos(u8, data, offset, 0) orelse
        return error.InvalidData) + 1;
    while (offset < data.len and data[offset] == 0) : (offset += 1) {}
    const command_start = offset;
    for (0..argc) |_| {
        offset = (std.mem.indexOfScalarPos(u8, data, offset, 0) orelse
            return error.InvalidData) + 1;
    }
    const selected = switch (part) {
        .command => data[command_start..offset],
        .environment => environmentSlice(data, offset),
    };
    std.mem.copyForwards(u8, data[0..selected.len], selected);
    return data[0..selected.len];
}

fn environmentSlice(data: []u8, start: usize) []u8 {
    if (start >= data.len) return data[0..0];
    var end = data.len;
    while (end > start and data[end - 1] == 0) : (end -= 1) {}
    if (end == start) return data[0..0];
    return data[start..@min(data.len, end + 1)];
}

fn compactPids(values: []types.ProcessId) []types.ProcessId {
    var count: usize = 0;
    for (values) |pid| {
        if (pid <= 0) continue;
        values[count] = pid;
        count += 1;
    }
    std.mem.sort(types.ProcessId, values[0..count], {}, std.sort.asc(types.ProcessId));
    return values[0..count];
}

fn copyText(storage: []u8, value: []const u8) types.Error![]const u8 {
    if (value.len > storage.len) return error.BufferTooSmall;
    @memcpy(storage[0..value.len], value);
    return storage[0..value.len];
}

fn systemFailure() types.Error {
    return switch (std.c.errno(-1)) {
        .SRCH, .NOENT => error.ProcessNotFound,
        .ACCES, .PERM => error.PermissionDenied,
        .NOMEM => error.BufferTooSmall,
        else => error.QueryFailed,
    };
}

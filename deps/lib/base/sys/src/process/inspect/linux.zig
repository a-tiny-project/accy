const std = @import("std");
const types = @import("types.zig");

const io = std.Options.debug_io;
const linux = std.os.linux;
const stat_bytes_max: usize = 4096;
const statm_bytes_max: usize = 128;
const child_text_bytes_max: usize = 12 * 1024;

const Stat = struct {
    parent_pid: types.ProcessId,
    state: u8,
    start_ticks: u64,
};

pub fn list(storage: []types.ProcessId) types.Error![]types.ProcessId {
    var directory = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch
        return error.QueryFailed;
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (iterator.next(io) catch return error.QueryFailed) |entry| {
        const pid = std.fmt.parseUnsigned(types.ProcessId, entry.name, 10) catch continue;
        if (pid <= 0) continue;
        if (count == storage.len) return error.BufferTooSmall;
        storage[count] = pid;
        count += 1;
    }
    std.mem.sort(types.ProcessId, storage[0..count], {}, std.sort.asc(types.ProcessId));
    return storage[0..count];
}

pub fn children(
    pid: types.ProcessId,
    storage: []types.ProcessId,
) types.Error![]types.ProcessId {
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_storage,
        "/proc/{d}/task/{d}/children",
        .{ pid, pid },
    ) catch return error.BufferTooSmall;
    var text_storage: [child_text_bytes_max]u8 = undefined;
    const text = try readAbsolute(path, &text_storage);
    var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var count: usize = 0;
    while (fields.next()) |field| {
        const child = std.fmt.parseUnsigned(types.ProcessId, field, 10) catch
            return error.InvalidData;
        if (child <= 0) return error.InvalidData;
        if (count == storage.len) return error.BufferTooSmall;
        storage[count] = child;
        count += 1;
    }
    return storage[0..count];
}

pub fn info(pid: types.ProcessId) types.Error!types.Info {
    if (pid <= 0) return error.ProcessNotFound;
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_storage, "/proc/{d}/stat", .{pid}) catch
        return error.BufferTooSmall;
    var stat_storage: [stat_bytes_max]u8 = undefined;
    const observed = try parseStat(try readAbsolute(path, &stat_storage));
    return .{
        .parent_pid = observed.parent_pid,
        .start = .{ .linux_ticks = observed.start_ticks },
        .alive = observed.state != 'X' and observed.state != 'Z',
        .private_bytes = privateBytes(pid),
    };
}

pub fn group(pid: types.ProcessId) types.Error!types.ProcessId {
    if (pid <= 0) return error.ProcessNotFound;
    const rc = linux.getpgid(pid);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .SRCH => error.ProcessNotFound,
        else => error.QueryFailed,
    };
}

pub fn exists(pid: types.ProcessId) types.Error!bool {
    _ = info(pid) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return err,
    };
    return true;
}

/// Opens a descriptor that polls readable once the process exits, before its parent reaps it.
/// The descriptor names that process alone, so a later reuse of its identifier never signals it.
pub fn exitDescriptor(pid: types.ProcessId) types.Error!types.Descriptor {
    if (pid <= 0) return error.ProcessNotFound;
    const rc = linux.pidfd_open(pid, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .SRCH => error.ProcessNotFound,
        .PERM, .ACCES => error.PermissionDenied,
        else => error.QueryFailed,
    };
}

pub fn name(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_storage, "/proc/{d}/comm", .{pid}) catch
        return error.BufferTooSmall;
    const value = std.mem.trimEnd(u8, try readAbsolute(path, storage), "\n");
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '\n') != null) {
        return error.InvalidData;
    }
    return value;
}

pub fn cwd(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    if (storage.len == 0) return error.BufferTooSmall;
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_storage, "/proc/{d}/cwd", .{pid}) catch
        return error.BufferTooSmall;
    const count = std.Io.Dir.cwd().readLink(io, path, storage) catch
        return error.ProcessNotFound;
    if (count == storage.len) return error.BufferTooSmall;
    return storage[0..count];
}

/// Fills the caller's storage with the numbers of another process's open
/// descriptors, read from `/proc/<pid>/fd` and sorted ascending, so a caller
/// can then ask about any one of them. The scan works in the caller's slice and
/// reaches no allocator, filling at most as many numbers as the slice holds, so
/// a result that came back exactly as long as the slice leaves a caller unable
/// to tell whether more descriptors were open. An empty storage slice fails
/// with `BufferTooSmall`, a missing process with `ProcessNotFound`, and a
/// process the caller lacks permission to read with `PermissionDenied`.
pub fn fds(
    pid: types.ProcessId,
    storage: []types.Descriptor,
) types.Error![]types.Descriptor {
    if (pid <= 0) return error.ProcessNotFound;
    if (storage.len == 0) return error.BufferTooSmall;
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_storage, "/proc/{d}/fd", .{pid}) catch
        return error.BufferTooSmall;
    var directory = std.Io.Dir.openDirAbsolute(
        io,
        path,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound => return error.ProcessNotFound,
        error.AccessDenied => return error.PermissionDenied,
        else => return error.QueryFailed,
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (iterator.next(io) catch return error.QueryFailed) |entry| {
        const descriptor = std.fmt.parseInt(types.Descriptor, entry.name, 10) catch
            continue;
        if (descriptor < 0) continue;
        if (count == storage.len) break;
        storage[count] = descriptor;
        count += 1;
    }
    std.mem.sort(
        types.Descriptor,
        storage[0..count],
        {},
        std.sort.asc(types.Descriptor),
    );
    return storage[0..count];
}

/// Turns one descriptor number into the path it points at, by resolving that
/// descriptor's link under `/proc/<pid>/fd/<fd>` into the caller's storage with
/// no allocator, so a caller can tell whether that process is the one holding a
/// given file. A link that exactly fills the storage fails with
/// `BufferTooSmall`, because the result may have been cut short. A missing
/// process or descriptor gives `ProcessNotFound`, and an unreadable one gives
/// `PermissionDenied`.
pub fn fdPath(
    pid: types.ProcessId,
    descriptor: types.Descriptor,
    storage: []u8,
) types.Error![]const u8 {
    if (pid <= 0 or descriptor < 0) return error.ProcessNotFound;
    if (storage.len == 0) return error.BufferTooSmall;
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_storage,
        "/proc/{d}/fd/{d}",
        .{ pid, descriptor },
    ) catch return error.BufferTooSmall;
    const count = std.Io.Dir.cwd().readLink(io, path, storage) catch |err| switch (err) {
        error.FileNotFound => return error.ProcessNotFound,
        error.AccessDenied => return error.PermissionDenied,
        else => return error.QueryFailed,
    };
    if (count == storage.len) return error.BufferTooSmall;
    return storage[0..count];
}

/// Reports whether a BSD flock lock is held on the open file description behind
/// `descriptor` for process `pid`, read from `/proc/<pid>/fdinfo/<fd>`. Only
/// the `FLOCK ADVISORY` lines carrying a read or a write mode are matched, so a
/// held POSIX record lock, an open file with no lock, and a request still
/// waiting for one all report false.
pub fn fdFlock(pid: types.ProcessId, descriptor: types.Descriptor) types.Error!bool {
    if (pid <= 0 or descriptor < 0) return error.ProcessNotFound;
    var name_storage: [48]u8 = undefined;
    const file = std.fmt.bufPrint(&name_storage, "fdinfo/{d}", .{descriptor}) catch
        return error.BufferTooSmall;
    var storage: [4096]u8 = undefined;
    return hasFlock(try readProcessFile(pid, file, &storage));
}

fn hasFlock(bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        if (!std.mem.eql(u8, fields.next() orelse continue, "lock:")) continue;
        _ = fields.next() orelse continue;
        if (!std.mem.eql(u8, fields.next() orelse continue, "FLOCK")) continue;
        if (!std.mem.eql(u8, fields.next() orelse continue, "ADVISORY")) continue;
        const mode = fields.next() orelse continue;
        if (std.mem.eql(u8, mode, "READ") or std.mem.eql(u8, mode, "WRITE")) return true;
    }
    return false;
}

pub fn command(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    return readProcessFile(pid, "cmdline", storage);
}

pub fn environment(pid: types.ProcessId, storage: []u8) types.Error![]const u8 {
    return readProcessFile(pid, "environ", storage);
}

pub fn hostname(storage: []u8) types.Error![]const u8 {
    const value = std.mem.trim(u8, try readAbsolute(
        "/proc/sys/kernel/hostname",
        storage,
    ), " \t\r\n");
    return if (value.len == 0) error.InvalidData else value;
}

pub fn pidNamespace(storage: []u8) types.Error![]const u8 {
    if (storage.len == 0) return error.BufferTooSmall;
    const count = std.Io.Dir.cwd().readLink(io, "/proc/self/ns/pid", storage) catch
        return error.QueryFailed;
    if (count == storage.len) return error.BufferTooSmall;
    return storage[0..count];
}

pub fn cgroup(storage: []u8) types.Error![]const u8 {
    return readAbsolute("/proc/self/cgroup", storage);
}

fn readProcessFile(
    pid: types.ProcessId,
    name_value: []const u8,
    storage: []u8,
) types.Error![]const u8 {
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_storage,
        "/proc/{d}/{s}",
        .{ pid, name_value },
    ) catch return error.BufferTooSmall;
    return readAbsolute(path, storage);
}

fn readAbsolute(path: []const u8, storage: []u8) types.Error![]const u8 {
    if (storage.len == 0) return error.BufferTooSmall;
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err|
        return openError(err);
    defer file.close(io);
    const count = try readAll(file.handle, storage);
    if (count == storage.len) return error.BufferTooSmall;
    return storage[0..count];
}

fn readAll(descriptor: linux.fd_t, storage: []u8) types.Error!usize {
    std.debug.assert(descriptor >= 0);
    std.debug.assert(storage.len > 0);
    var count: usize = 0;
    while (count < storage.len) {
        const result = linux.pread(
            descriptor,
            storage[count..].ptr,
            storage.len - count,
            @intCast(count),
        );
        switch (linux.errno(result)) {
            .SUCCESS => {
                std.debug.assert(result <= storage.len - count);
                if (result == 0) break;
                count += result;
            },
            .INTR => continue,
            else => |errno_value| return readError(errno_value),
        }
    }
    return count;
}

/// Only a missing file proves that a process is gone. The open reports
/// ENOENT, and ESRCH from a procfs file of an exiting process, as
/// `FileNotFound`. A denied or failed open leaves the process as it was.
fn openError(err: std.Io.File.OpenError) types.Error {
    return switch (err) {
        error.FileNotFound => error.ProcessNotFound,
        error.AccessDenied, error.PermissionDenied => error.PermissionDenied,
        else => error.QueryFailed,
    };
}

fn readError(errno_value: linux.E) types.Error {
    std.debug.assert(errno_value != .SUCCESS);
    std.debug.assert(errno_value != .INTR);
    return switch (errno_value) {
        .NOENT, .SRCH => error.ProcessNotFound,
        .ACCES, .PERM => error.PermissionDenied,
        else => error.QueryFailed,
    };
}

fn parseStat(data: []const u8) types.Error!Stat {
    const separator = std.mem.lastIndexOf(u8, data, ") ") orelse
        return error.InvalidData;
    var fields = std.mem.tokenizeAny(u8, data[separator + 2 ..], " \t\r\n");
    const state = fields.next() orelse return error.InvalidData;
    if (state.len != 1) return error.InvalidData;
    var parent_pid: ?types.ProcessId = null;
    var start_ticks: ?u64 = null;
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index == 0) parent_pid = std.fmt.parseInt(types.ProcessId, field, 10) catch
            return error.InvalidData;
        if (index == 18) start_ticks = std.fmt.parseUnsigned(u64, field, 10) catch
            return error.InvalidData;
        if (start_ticks != null) break;
    }
    return .{
        .parent_pid = parent_pid orelse return error.InvalidData,
        .state = state[0],
        .start_ticks = start_ticks orelse return error.InvalidData,
    };
}

/// statm's second field counts resident pages and its third the resident
/// pages backed by a file or by shared memory, so their difference is the
/// process's anonymous resident pages: heap, stacks and other memory no file
/// backs. The two counters are read together but not atomically, so a
/// difference below zero saturates to zero.
fn privateBytes(pid: types.ProcessId) ?u64 {
    var storage: [statm_bytes_max]u8 = undefined;
    const data = readProcessFile(pid, "statm", &storage) catch return null;
    var fields = std.mem.tokenizeAny(u8, data, " \t\r\n");
    _ = fields.next() orelse return null;
    const resident = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 10) catch
        return null;
    const shared = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 10) catch
        return null;
    return pageBytes(resident -| shared, std.heap.pageSize());
}

/// statm counts pages, whose size is the host's: 4 KiB on x86_64, and 16 or
/// 64 KiB on some AArch64 kernels. A count too large for u64 saturates.
fn pageBytes(pages: u64, page_size: usize) u64 {
    std.debug.assert(page_size > 0);
    return std.math.mul(u64, pages, page_size) catch std.math.maxInt(u64);
}

fn waitTestChild(pid: linux.pid_t) error{WaitFailed}!usize {
    std.debug.assert(pid > 0);
    var status: i32 = undefined;
    while (true) {
        const result = linux.waitpid(pid, &status, 0);
        switch (linux.errno(result)) {
            .SUCCESS => return result,
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
}

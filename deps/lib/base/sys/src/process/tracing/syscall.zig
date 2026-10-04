const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const Operation = enum { open, openat, openat2, creat, rename, renameat, renameat2 };
pub const FileCall = struct {
    operation: Operation,
    path: u64,
    path2: u64 = 0,
    directory: i32 = -100,
    directory2: i32 = -100,
    flags: ?u64 = null,
};
pub const Phase = union(enum) { entry: ?FileCall, exit: i64 };
const Info = extern struct {
    op: u8,
    pad: [3]u8,
    arch: u32,
    ip: u64,
    sp: u64,
    data: extern union {
        entry: extern struct { nr: u64, args: [6]u64 },
        exit: extern struct { value: i64, failed: u8 },
    },
};

pub fn inspect(pid: i32) !Phase {
    var info: Info = std.mem.zeroes(Info);
    const result = linux.ptrace(
        linux.PTRACE.GET_SYSCALL_INFO,
        pid,
        @sizeOf(Info),
        @intFromPtr(&info),
        0,
    );
    if (linux.errno(result) != .SUCCESS) return error.SyscallObservationUnavailable;
    const arch: u32 = switch (builtin.cpu.arch) {
        .x86_64 => 0xc000003e,
        .aarch64 => 0xc00000b7,
        else => return error.UnsupportedSyscallArchitecture,
    };
    if (info.arch != arch) return error.UnsupportedTraceeArchitecture;
    if (info.op == 1 and result < 80) return error.IncompleteSyscallObservation;
    if (info.op == 2 and result < 33) return error.IncompleteSyscallObservation;
    if (builtin.cpu.arch == .x86_64 and info.op == 1 and
        (info.data.entry.nr & 0x40000000) != 0) return error.UnsupportedTraceeArchitecture;
    return switch (info.op) {
        1 => .{ .entry = decode(info.data.entry.nr, info.data.entry.args) },
        2 => .{ .exit = info.data.exit.value },
        else => error.IncompleteSyscallObservation,
    };
}

fn number(comptime name: []const u8, nr: u64) bool {
    if (comptime @hasField(linux.SYS, name)) return nr == @backingInt(@field(linux.SYS, name));
    return false;
}

fn directory(value: u64) i32 {
    return @bitCast(@as(u32, @truncate(value)));
}

fn decode(nr: u64, args: [6]u64) ?FileCall {
    if (number("open", nr)) return .{ .operation = .open, .path = args[0], .flags = args[1] };
    if (number("creat", nr)) return .{ .operation = .creat, .path = args[0], .flags = 0x241 };
    if (number("openat", nr) or number("openat2", nr)) return .{
        .operation = if (number("openat", nr)) .openat else .openat2,
        .directory = directory(args[0]),
        .path = args[1],
        .flags = if (number("openat", nr)) args[2] else null,
    };
    if (number("rename", nr)) return .{ .operation = .rename, .path = args[0], .path2 = args[1] };
    if (number("renameat", nr) or number("renameat2", nr)) return .{
        .operation = if (number("renameat", nr)) .renameat else .renameat2,
        .directory = directory(args[0]),
        .path = args[1],
        .directory2 = directory(args[2]),
        .path2 = args[3],
        .flags = if (number("renameat2", nr)) args[4] else 0,
    };
    return null;
}

/// Turns a path argument at a syscall stop into bytes a recorder can write down
/// by copying the path out of a stopped tracee's memory at `address` into
/// `buffer`, and then returning the bytes before the terminator. A zero or
/// out-of-range address, a failed read, and a copy that holds no terminator
/// each return null, and the last marks a path longer than the buffer.
pub fn path(pid: i32, address: u64, buffer: []u8) ?[]const u8 {
    if (address == 0 or address > std.math.maxInt(usize)) return null;
    const local = [_]std.posix.iovec{.{ .base = buffer.ptr, .len = buffer.len }};
    const remote = [_]std.posix.iovec_const{.{
        .base = @ptrFromInt(@as(usize, @intCast(address))),
        .len = buffer.len,
    }};
    const result = linux.process_vm_readv(pid, &local, &remote, 0);
    if (linux.errno(result) != .SUCCESS) return null;
    const end = std.mem.indexOfScalar(u8, buffer[0..result], 0) orelse return null;
    return buffer[0..end];
}

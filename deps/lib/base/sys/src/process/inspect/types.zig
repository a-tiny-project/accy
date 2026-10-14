const std = @import("std");

pub const Error = error{
    UnsupportedPlatform,
    ProcessNotFound,
    PermissionDenied,
    BufferTooSmall,
    InvalidData,
    QueryFailed,
};

pub const ProcessId = i32;
pub const Descriptor = i32;

pub const DarwinTime = struct {
    seconds: u64,
    microseconds: u64,
};

pub const Start = union(enum) {
    linux_ticks: u64,
    darwin_time: DarwinTime,

    pub fn token(self: Start, storage: []u8) Error![]const u8 {
        return switch (self) {
            .linux_ticks => |ticks| std.fmt.bufPrint(
                storage,
                "proc:{d}",
                .{ticks},
            ) catch error.BufferTooSmall,
            .darwin_time => |time| std.fmt.bufPrint(
                storage,
                "darwin:{d}:{d}",
                .{ time.seconds, time.microseconds },
            ) catch error.BufferTooSmall,
        };
    }
};

pub fn parseStartToken(value: []const u8) ?Start {
    const linux_prefix = "proc:";
    if (std.mem.startsWith(u8, value, linux_prefix)) {
        const ticks = value[linux_prefix.len..];
        if (ticks.len == 0) return null;
        return .{
            .linux_ticks = std.fmt.parseUnsigned(u64, ticks, 10) catch return null,
        };
    }

    const darwin_prefix = "darwin:";
    if (!std.mem.startsWith(u8, value, darwin_prefix)) return null;
    const time = value[darwin_prefix.len..];
    const separator = std.mem.indexOfScalar(u8, time, ':') orelse return null;
    const seconds = time[0..separator];
    const microseconds = time[separator + 1 ..];
    if (seconds.len == 0 or microseconds.len == 0 or
        std.mem.indexOfScalar(u8, microseconds, ':') != null) return null;
    return .{ .darwin_time = .{
        .seconds = std.fmt.parseUnsigned(u64, seconds, 10) catch return null,
        .microseconds = std.fmt.parseUnsigned(u64, microseconds, 10) catch return null,
    } };
}

pub const Info = struct {
    parent_pid: ProcessId,
    start: Start,
    /// Whether any thread of the process still runs. A process whose leader
    /// thread exited while others run is alive; one whose last thread exited
    /// is not, though its parent has yet to reap it.
    alive: bool,
    /// Resident memory that belongs to this process alone, or null when the
    /// platform does not report it. Pages that processes share, such as a
    /// memory-mapped file, are left out: a sum of resident sets over a process
    /// tree counts each shared page once per process that maps it, and the
    /// kernel can reclaim clean file pages under pressure.
    private_bytes: ?u64,
};

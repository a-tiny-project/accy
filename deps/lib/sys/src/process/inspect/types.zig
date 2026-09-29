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
    alive: bool,
    resident_bytes: ?u64,
};

test "process start tokens preserve backend identity" {
    var storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "proc:42",
        try (Start{ .linux_ticks = 42 }).token(&storage),
    );
    try std.testing.expectEqualStrings(
        "darwin:7:9",
        try (Start{ .darwin_time = .{
            .seconds = 7,
            .microseconds = 9,
        } }).token(&storage),
    );
    try std.testing.expectError(
        error.BufferTooSmall,
        (Start{ .linux_ticks = 42 }).token(storage[0..2]),
    );
}

test "process start tokens parse their exact portable grammar" {
    try std.testing.expectEqual(
        Start{ .linux_ticks = 42 },
        parseStartToken("proc:42").?,
    );
    try std.testing.expectEqual(
        Start{ .darwin_time = .{ .seconds = 7, .microseconds = 9 } },
        parseStartToken("darwin:7:9").?,
    );

    const malformed = [_][]const u8{
        "",
        "proc:",
        "proc:1:2",
        "proc:-1",
        "darwin:",
        "darwin:1",
        "darwin::1",
        "darwin:1:",
        "darwin:1:2:3",
        "ps:42",
        "proc:18446744073709551616",
        "darwin:18446744073709551616:0",
    };
    for (malformed) |value| {
        try std.testing.expectEqual(@as(?Start, null), parseStartToken(value));
    }
}

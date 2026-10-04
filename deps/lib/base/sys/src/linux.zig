const std = @import("std");

pub const Errno = enum(usize) {
    success = 0,
    intr = 4,
    _,
};

pub fn getRandom(buffer: []u8) usize {
    return std.os.linux.getrandom(buffer.ptr, buffer.len, 0);
}

pub fn processId() std.os.linux.pid_t {
    return std.os.linux.getpid();
}

pub fn errno(rc: usize) Errno {
    const signed: isize = @bitCast(rc);
    const code = if (signed > -4096 and signed < 0) -signed else 0;
    return @fromBackingInt(@intCast(@as(usize, @intCast(code))));
}

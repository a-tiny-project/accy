const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");

const native_os = builtin.os.tag;
const posix = std.posix;

pub const required_capabilities = switch (native_os) {
    .linux => capabilities.noLibc(&.{ .descriptors, .event_loop }),
    else => capabilities.host(&.{ .descriptors, .event_loop }),
};

pub const Descriptor = posix.pollfd;
pub const TimeSpec = posix.timespec;
pub const SignalSet = posix.sigset_t;
pub const WaitError = posix.PollError || error{UnsupportedPlatform};
pub const PreciseWaitError = posix.PPollError || error{UnsupportedPlatform};

pub const Event = struct {
    pub const input = posix.POLL.IN;
    pub const output = posix.POLL.OUT;
    pub const error_condition = posix.POLL.ERR;
    pub const hangup = posix.POLL.HUP;
    pub const invalid = posix.POLL.NVAL;
};

pub fn wait(descriptors: []Descriptor, timeout_ms: i32) WaitError!usize {
    if (comptime !supported()) return error.UnsupportedPlatform;
    return posix.poll(descriptors, timeout_ms);
}

pub fn waitPrecise(
    descriptors: []Descriptor,
    timeout: ?*const TimeSpec,
    signal_mask: ?*const SignalSet,
) PreciseWaitError!usize {
    if (comptime !preciseSupported()) return error.UnsupportedPlatform;
    return posix.ppoll(descriptors, timeout, signal_mask);
}

/// Whether `waitPrecise` runs here. Apple's libc has no `ppoll`.
pub fn preciseSupported() bool {
    return supported() and !native_os.isDarwin();
}

pub fn supported() bool {
    return switch (native_os) {
        .windows, .wasi, .freestanding => false,
        else => true,
    };
}

test "poll waits preserve descriptor readiness" {
    if (!supported()) return error.SkipZigTest;
    const fd = @import("fd.zig");
    const descriptors = try fd.pipeWithOptions(.{});
    defer fd.close(descriptors[0]);
    defer fd.close(descriptors[1]);

    var poll_descriptors = [_]Descriptor{.{
        .fd = descriptors[0],
        .events = Event.input,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try wait(&poll_descriptors, 0));
    try std.testing.expectEqual(@as(usize, 1), try fd.write(descriptors[1], "x"));
    try std.testing.expectEqual(@as(usize, 1), try wait(&poll_descriptors, 0));

    if (!preciseSupported()) return;
    const timeout = TimeSpec{ .sec = 0, .nsec = 0 };
    try std.testing.expectEqual(
        @as(usize, 1),
        try waitPrecise(&poll_descriptors, &timeout, null),
    );
}

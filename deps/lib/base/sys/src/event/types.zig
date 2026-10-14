const std = @import("std");
const sys = @import("../root.zig");

pub const AcceptError = error{
    Canceled,
    Again,
    Unexpected,
};

pub const CloseError = error{
    Canceled,
    Unexpected,
};

pub const PollError = error{
    Canceled,
    Unexpected,
};

pub const ReadError = error{
    EOF,
    Canceled,
    ConnectionResetByPeer,
    Unexpected,
};

pub const RecvError = error{
    Canceled,
    ConnectionResetByPeer,
    Unexpected,
};

pub const SendError = error{
    Canceled,
    BrokenPipe,
    ConnectionResetByPeer,
    MessageTooLarge,
    Unexpected,
};

pub const WriteError = error{
    Canceled,
    BrokenPipe,
    ConnectionResetByPeer,
    Unexpected,
};

/// Record of one UDP message that arrived, read once a UDP receive completes to
/// learn who sent the message and whether all of it arrived. A caller hands a
/// buffer to the event loop when it arms a receive. The payload byte count
/// reports what landed in that armed buffer and stops at its length, and a
/// separate flag reports whether the message ran past the end of it. On Linux
/// the flag is exact, because the kernel reports the message's full length and
/// the receive compares it against the buffer length, while on every other host
/// the flag is set whenever the byte count equals the armed buffer's length, so
/// a message that exactly fills the buffer reports as truncated.
pub const Datagram = struct {
    address: sys.net.IpAddress,
    bytes: usize,
    truncated: bool,
};

pub const Options = struct {
    entries: u32 = 256,
    allocator: std.mem.Allocator = sys.allocator.processAllocator(),
    awake_clock: sys.time.AwakeClock = .system(),
};

pub const RunMode = enum {
    /// Dispatch one readiness batch without waiting. Due timers run in deadline
    /// and slot order, followed by ready descriptors in slot order.
    no_wait,
    /// Wait for readiness or the earliest timer, then dispatch one batch.
    /// Each surviving completion fires at most once; rearms wait for the next
    /// batch, and callback mutations invalidate the affected pending callback.
    once,
    /// Repeat readiness batches until every completion is disarmed.
    until_done,
};

pub const CallbackAction = enum {
    disarm,
    rearm,
};

pub const PollEvent = enum {
    read,
};

pub const ReadBuffer = union(enum) {
    slice: []u8,
    array: [32]u8,
};

pub const WriteBuffer = union(enum) {
    slice: []const u8,
    array: struct {
        array: [32]u8,
        len: usize,
    },
};

const std = @import("std");

/// A delivery target holding a type-erased context pointer and a function
/// pointer that accepts an event by value. Delivery occurs synchronously on
/// the recording thread with no intermediate queue, so events from distinct
/// threads can arrive concurrently and the callback must synchronize access to
/// shared state. The caller must keep the `Sink` storage, its context, and its
/// code valid until `Session.deinit` returns.
fn ChannelSink(comptime Event: type) type {
    return struct {
        context: *anyopaque,
        record: *const fn (context: *anyopaque, event: Event) void,
    };
}

/// An installed observation interval that borrows caller-owned sink storage.
/// The session must be terminated by calling `deinit` exactly once. Callers
/// serialize session lifecycles externally: the channel does not overlap one
/// session's shutdown with the installation of the next.
fn ChannelSession(comptime Event: type) type {
    return struct {
        sink: ?*const Owner.Sink = null,
        active: bool = false,

        const Self: type = @This();
        const Owner: type = Channel(Event);

        /// Unregisters the sink and spins until the in-flight delivery count
        /// drains to zero. The spin has no timeout, so callers must invoke
        /// `deinit` outside callbacks and suppression scopes, with no bracket
        /// open on the calling thread, and without holding a lock an
        /// in-flight callback needs.
        pub fn deinit(self: *Self) void {
            std.debug.assert(Owner.callback_depth == 0);
            std.debug.assert(self.active);
            const address = @intFromPtr(self.sink.?);
            const previous = Owner.active_sink.cmpxchgStrong(
                address,
                0,
                .seq_cst,
                .seq_cst,
            );
            std.debug.assert(previous == null);
            while (Owner.active_operations.load(.seq_cst) != 0) {
                std.atomic.spinLoopHint();
            }
            self.active = false;
            self.sink = null;
        }
    };
}

/// A nesting token that stops the current thread's events from reaching the
/// sink while it is active. It mutes no other thread and leaves brackets
/// opened before it untouched.
fn ChannelSuppression(comptime Event: type) type {
    return struct {
        active: bool = true,

        const Self: type = @This();
        const Owner: type = Channel(Event);

        /// Restores the thread's callback depth by one level. The token must
        /// be released on its originating thread. Repeated calls are no-ops,
        /// but copies of an active token must not be released independently.
        pub fn deinit(self: *Self) void {
            if (!self.active) return;
            std.debug.assert(Owner.callback_depth > 0);
            Owner.callback_depth -= 1;
            self.active = false;
        }
    };
}

/// Returns the sink channel for one event type. A channel delivers each event
/// synchronously to at most one installed sink, on the thread that records it.
/// Every instantiation owns its own sink slot, in-flight delivery count, and
/// per-thread callback depth, so channels for different event types install,
/// suppress, and drain independently. Instantiating the same event type twice
/// yields the same channel.
///
/// The channel holds three invariants:
///
/// - One sink at a time: `install` claims the slot by compare-and-swap and
///   reports `AlreadyInstalled` while another session holds it.
/// - `Session.deinit` returns only after every in-flight delivery, and every
///   bracket opened with `acquire`, has released.
/// - A sink callback never observes an event its own thread records, because
///   delivery raises the thread's callback depth for its duration.
///
/// `install` must come from outside callbacks and suppression scopes, and
/// producers on other threads may deliver before it returns. `acquire` opens a
/// bracket that holds `Session.deinit` until the same thread calls `release`,
/// so a caller may span a whole operation and `deliver` at its end. `record`
/// is the one-event bracket. Each returns without effect when the thread is
/// suppressed or no sink is installed.
pub fn Channel(comptime Event: type) type {
    return struct {
        pub const Sink: type = ChannelSink(Event);
        pub const Session: type = ChannelSession(Event);
        pub const Suppression: type = ChannelSuppression(Event);

        // The drain is a store-buffering (Dekker) pair: `acquire` raises the
        // count and then reads the sink, while `Session.deinit` clears the
        // sink and then reads the count. Those four operations are `seq_cst`
        // so that both sides cannot read the other's stale value, which would
        // let `deinit` return while a callback is about to run.
        var active_sink = std.atomic.Value(usize).init(0);
        var active_operations = std.atomic.Value(usize).init(0);
        threadlocal var callback_depth: u8 = 0;

        pub fn install(sink: *const Sink) error{AlreadyInstalled}!Session {
            std.debug.assert(callback_depth == 0);
            const address = @intFromPtr(sink);
            std.debug.assert(address != 0);
            const claimed = active_sink.cmpxchgStrong(0, address, .acq_rel, .acquire);
            if (claimed != null) return error.AlreadyInstalled;
            return .{ .sink = sink, .active = true };
        }

        pub inline fn suppress() Suppression {
            std.debug.assert(callback_depth < std.math.maxInt(u8));
            callback_depth += 1;
            return .{};
        }

        pub inline fn suppressed() bool {
            return callback_depth != 0;
        }

        pub inline fn acquire() ?*const Sink {
            if (callback_depth != 0) return null;
            const held = active_operations.fetchAdd(1, .seq_cst);
            std.debug.assert(held < std.math.maxInt(usize));
            const sink_address = active_sink.load(.seq_cst);
            if (sink_address == 0) {
                release();
                return null;
            }
            return @ptrFromInt(sink_address);
        }

        pub inline fn deliver(sink: *const Sink, event: Event) void {
            std.debug.assert(callback_depth < std.math.maxInt(u8));
            callback_depth += 1;
            sink.record(sink.context, event);
            callback_depth -= 1;
        }

        pub inline fn release() void {
            const held = active_operations.fetchSub(1, .release);
            std.debug.assert(held > 0);
        }

        pub inline fn record(event: Event) void {
            const sink = acquire() orelse return;
            deliver(sink, event);
            release();
        }
    };
}

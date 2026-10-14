const std = @import("std");
const sys = @import("../root.zig");
const types = @import("types.zig");

const fd = sys.fd;
const net = sys.net;
const descriptor_poll = sys.poll;
const time = sys.time;

pub const AcceptError = types.AcceptError;
pub const CallbackAction = types.CallbackAction;
pub const CloseError = types.CloseError;
pub const Datagram = types.Datagram;
pub const Options = types.Options;
pub const PollError = types.PollError;
pub const PollEvent = types.PollEvent;
pub const ReadBuffer = types.ReadBuffer;
pub const ReadError = types.ReadError;
pub const RecvError = types.RecvError;
pub const RunMode = types.RunMode;
pub const SendError = types.SendError;
pub const WriteBuffer = types.WriteBuffer;
pub const WriteError = types.WriteError;

const Callback = *const fn (?*anyopaque, *Loop, *Completion, Result) CallbackAction;

const Result = union(enum) {
    async_wait: Async.WaitError!void,
    timer: Timer.RunError!void,
    tcp_accept: AcceptError!TCP,
    tcp_read: struct {
        socket: TCP,
        buffer: ReadBuffer,
        result: ReadError!usize,
    },
    tcp_write: struct {
        socket: TCP,
        buffer: WriteBuffer,
        result: WriteError!usize,
    },
    udp_recv_from: struct {
        socket: UDP,
        buffer: ReadBuffer,
        result: RecvError!Datagram,
    },
    udp_send_to: struct {
        socket: UDP,
        buffer: WriteBuffer,
        result: SendError!usize,
    },
    tcp_close: struct {
        socket: TCP,
        result: CloseError!void,
    },
    file_poll: struct {
        file: File,
        result: PollError!PollEvent,
    },
};

const Operation = union(enum) {
    none,
    async_wait: Async,
    timer: TimerState,
    tcp_accept: TCP,
    tcp_read: TcpReadState,
    tcp_write: TcpWriteState,
    udp_recv_from: UdpRecvFromState,
    udp_send_to: UdpSendToState,
    file_poll: FilePollState,

    fn descriptor(self: Operation) ?fd.Descriptor {
        return switch (self) {
            .none, .timer => null,
            .async_wait => |async_watcher| async_watcher.read_fd,
            .tcp_accept => |socket| socket.fd,
            .tcp_read => |state| state.socket.fd,
            .tcp_write => |state| state.socket.fd,
            .udp_recv_from => |state| state.socket.fd,
            .udp_send_to => |state| state.socket.fd,
            .file_poll => |state| state.file.fd,
        };
    }

    fn events(self: Operation) i16 {
        return switch (self) {
            .tcp_write, .udp_send_to => descriptor_poll.Event.output,
            else => descriptor_poll.Event.input,
        };
    }
};

const TimerState = struct {
    deadline: time.AwakeInstant,
    repeat: ?Timer.Repeat,
};

const TcpReadState = struct {
    socket: TCP,
    buffer: ReadBuffer,
};

const TcpWriteState = struct {
    socket: TCP,
    buffer: WriteBuffer,
};

const UdpRecvFromState = struct {
    socket: UDP,
    buffer: ReadBuffer,
};

const UdpSendToState = struct {
    socket: UDP,
    buffer: WriteBuffer,
    address: net.IpAddress,
};

const FilePollState = struct {
    file: File,
    event: PollEvent,
};

const ReadinessSnapshot = struct {
    poll_count: usize,
    timer_begin: usize,
    timeout_ms: i32,
};

/// Caller-owned storage that stays valid while armed. Disarm a completion before
/// releasing its storage, including when another completion's callback owns it.
pub const Completion = struct {
    active: bool = false,
    entry_index: usize = 0,
    pending_index: ?usize = null,
    op: Operation = .none,
    userdata: ?*anyopaque = null,
    callback: ?Callback = null,
};

pub const Loop = struct {
    allocator: std.mem.Allocator,
    awake_clock: time.AwakeClock,
    last_instant: ?time.AwakeInstant,
    entries: []?*Completion,
    pollfds: []descriptor_poll.Descriptor,
    pending_completions: []?*Completion,
    active_count: usize = 0,

    pub fn init(options: Options) !Loop {
        const allocator = options.allocator;
        const count: usize = @intCast(options.entries);
        const entries = try allocator.alloc(?*Completion, count);
        errdefer allocator.free(entries);
        @memset(entries, null);

        const pollfds = try allocator.alloc(descriptor_poll.Descriptor, count);
        errdefer allocator.free(pollfds);

        const pending_completions = try allocator.alloc(?*Completion, count);
        errdefer allocator.free(pending_completions);

        return .{
            .allocator = allocator,
            .awake_clock = options.awake_clock,
            .last_instant = null,
            .entries = entries,
            .pollfds = pollfds,
            .pending_completions = pending_completions,
        };
    }

    pub fn deinit(self: *Loop) void {
        self.allocator.free(self.pending_completions);
        self.allocator.free(self.pollfds);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// A turn captures one readiness report and fires each surviving completion
    /// once. Callback mutations cancel that completion's pending report.
    pub fn run(self: *Loop, mode: RunMode) !void {
        while (self.hasActive()) {
            const snapshot = self.preparePoll(mode, try self.readInstant());
            var ready_count: usize = 0;
            if (snapshot.poll_count == 0) {
                if (snapshot.timeout_ms < 0) return;
                if (snapshot.timeout_ms > 0) {
                    const timeout_ns = @as(u64, @intCast(snapshot.timeout_ms)) *
                        std.time.ns_per_ms;
                    std.Io.sleep(
                        std.Options.debug_io,
                        .fromNanoseconds(timeout_ns),
                        .awake,
                    ) catch {};
                }
            } else {
                ready_count = descriptor_poll.wait(
                    self.pollfds[0..snapshot.poll_count],
                    snapshot.timeout_ms,
                ) catch return error.Unexpected;
            }

            const now = try self.readInstant();
            try self.fireDueTimers(snapshot.timer_begin, now);
            try self.fireAllReady(snapshot.poll_count, ready_count);
            if (mode != .until_done) return;
        }
    }

    pub fn currentInstant(self: *const Loop) time.AwakeInstant {
        return self.last_instant orelse @panic("sys.event loop has not sampled its awake clock");
    }

    pub fn awakeClock(self: *const Loop) time.AwakeClock {
        return self.awake_clock;
    }

    pub fn disarm(self: *Loop, completion: *Completion) void {
        self.deactivate(completion);
        completion.* = .{};
    }

    fn activate(self: *Loop, completion: *Completion) void {
        if (completion.active) {
            self.assertOwner(completion);
            return;
        }
        for (self.entries, 0..) |*slot, index| {
            if (slot.* == null) {
                slot.* = completion;
                completion.entry_index = index;
                completion.active = true;
                self.active_count += 1;
                return;
            }
        }
        @panic("sys.event loop completion capacity exhausted");
    }

    fn assertOwner(self: *const Loop, completion: *const Completion) void {
        if (completion.entry_index >= self.entries.len or
            self.entries[completion.entry_index] != completion)
        {
            @panic("sys.event active completion belongs to another loop");
        }
    }

    fn invalidatePending(self: *Loop, completion: *Completion) void {
        const index = completion.pending_index orelse return;
        std.debug.assert(self.pending_completions[index] == completion);
        self.pending_completions[index] = null;
        completion.pending_index = null;
    }

    fn arm(
        self: *Loop,
        completion: *Completion,
        op: Operation,
        userdata: ?*anyopaque,
        callback: Callback,
    ) void {
        if (completion.active) self.assertOwner(completion);
        self.invalidatePending(completion);
        const was_active = completion.active;
        const entry_index = completion.entry_index;
        completion.* = .{
            .active = was_active,
            .entry_index = entry_index,
            .op = op,
            .userdata = userdata,
            .callback = callback,
        };
        self.activate(completion);
    }

    fn deactivate(self: *Loop, completion: *Completion) void {
        if (!completion.active) return;
        self.assertOwner(completion);
        self.invalidatePending(completion);
        self.entries[completion.entry_index] = null;
        completion.active = false;
        std.debug.assert(self.active_count > 0);
        self.active_count -= 1;
    }

    fn deactivateDescriptor(self: *Loop, descriptor: fd.Descriptor) void {
        for (self.entries) |slot| {
            const completion = slot orelse continue;
            if (completion.op.descriptor()) |active_descriptor| {
                if (active_descriptor == descriptor) self.deactivate(completion);
            }
        }
    }

    fn hasActive(self: *const Loop) bool {
        return self.active_count != 0;
    }

    fn timerLessThan(_: void, lhs: ?*Completion, rhs: ?*Completion) bool {
        const left = lhs.?;
        const right = rhs.?;
        const left_deadline = left.op.timer.deadline;
        const right_deadline = right.op.timer.deadline;
        if (left_deadline.isBefore(right_deadline)) return true;
        if (right_deadline.isBefore(left_deadline)) return false;
        return left.entry_index < right.entry_index;
    }

    fn preparePoll(self: *Loop, mode: RunMode, now: time.AwakeInstant) ReadinessSnapshot {
        var count: usize = 0;
        var timer_begin = self.entries.len;
        var best: ?u64 = null;
        for (self.entries) |slot| {
            const completion = slot orelse continue;
            completion.pending_index = null;
            switch (completion.op) {
                .timer => |timer| {
                    timer_begin -= 1;
                    self.pending_completions[timer_begin] = completion;
                    const remaining = now.remainingUntil(timer.deadline).asMillisecondsCeil();
                    best = if (best) |current| @min(current, remaining) else remaining;
                },
                else => {
                    const descriptor = completion.op.descriptor() orelse continue;
                    self.pollfds[count] = .{
                        .fd = descriptor,
                        .events = completion.op.events(),
                        .revents = 0,
                    };
                    self.pending_completions[count] = completion;
                    completion.pending_index = count;
                    count += 1;
                },
            }
        }
        std.debug.assert(count <= timer_begin);
        const timers = self.pending_completions[timer_begin..];
        std.sort.heap(?*Completion, timers, {}, timerLessThan);
        for (timers, timer_begin..) |completion, index| {
            completion.?.pending_index = index;
        }
        const timeout_ms: i32 = if (mode == .no_wait) 0 else if (best) |value|
            @intCast(@min(value, std.math.maxInt(i32)))
        else
            -1;
        return .{
            .poll_count = count,
            .timer_begin = timer_begin,
            .timeout_ms = timeout_ms,
        };
    }

    fn fireDueTimers(self: *Loop, begin: usize, now: time.AwakeInstant) time.ClockError!void {
        // Rearms and newly armed timers belong to the next snapshot, even when
        // their deadline is already due. This bounds a turn by its initial set.
        for (self.pending_completions[begin..]) |pending| {
            const completion = pending orelse continue;
            std.debug.assert(completion.active);
            if (!now.reached(completion.op.timer.deadline)) break;
            try self.fire(completion, .{ .timer = {} });
        }
    }

    fn fireAllReady(self: *Loop, count: usize, ready_count: usize) time.ClockError!void {
        std.debug.assert(ready_count <= count);
        var remaining = ready_count;
        for (self.pollfds[0..count], 0..) |reported, index| {
            if (remaining == 0) break;
            if (reported.revents == 0) continue;
            remaining -= 1;
            // A callback can disarm and free another completion. Consult the
            // nullable snapshot before touching its caller-owned storage.
            const completion = self.pending_completions[index] orelse continue;
            std.debug.assert(completion.active);
            if (completion.op.descriptor() != reported.fd or
                completion.op.events() != reported.events) continue;
            try self.fireReady(completion);
        }
        std.debug.assert(remaining == 0);
    }

    fn fireReady(self: *Loop, completion: *Completion) time.ClockError!void {
        switch (completion.op) {
            .async_wait => |async_watcher| {
                async_watcher.drain();
                try self.fire(completion, .{ .async_wait = {} });
            },
            .tcp_accept => |socket| {
                const result = acceptSocket(socket);
                try self.fire(completion, .{ .tcp_accept = result });
            },
            .tcp_read => |*state| {
                const result = readSocket(state);
                try self.fire(completion, .{ .tcp_read = .{
                    .socket = state.socket,
                    .buffer = state.buffer,
                    .result = result,
                } });
            },
            .tcp_write => |*state| {
                const result = writeSocket(state);
                try self.fire(completion, .{ .tcp_write = .{
                    .socket = state.socket,
                    .buffer = state.buffer,
                    .result = result,
                } });
            },
            .udp_recv_from => |*state| try self.fireUdpRecvFrom(completion, state),
            .udp_send_to => |*state| try self.fireUdpSendTo(completion, state),
            .file_poll => |state| {
                try self.fire(completion, .{ .file_poll = .{
                    .file = state.file,
                    .result = state.event,
                } });
            },
            .none, .timer => {},
        }
    }

    fn fireUdpRecvFrom(
        self: *Loop,
        completion: *Completion,
        state: *UdpRecvFromState,
    ) time.ClockError!void {
        const received = net.recvFromIpAddress(
            state.socket.fd,
            readSlice(&state.buffer),
            0,
        ) catch |err| {
            if (err == error.WouldBlock) return;
            const result: RecvError = switch (err) {
                error.ConnectionResetByPeer => error.ConnectionResetByPeer,
                else => error.Unexpected,
            };
            try self.fire(completion, .{ .udp_recv_from = .{
                .socket = state.socket,
                .buffer = state.buffer,
                .result = result,
            } });
            return;
        };
        try self.fire(completion, .{ .udp_recv_from = .{
            .socket = state.socket,
            .buffer = state.buffer,
            .result = Datagram{
                .address = received.address,
                .bytes = received.bytes,
                .truncated = received.truncated,
            },
        } });
    }

    fn fireUdpSendTo(
        self: *Loop,
        completion: *Completion,
        state: *const UdpSendToState,
    ) time.ClockError!void {
        const bytes = writeSlice(&state.buffer);
        const sent = net.sendToIpAddress(state.socket.fd, bytes, 0, state.address) catch |err| {
            if (err == error.WouldBlock) return;
            const result: SendError = switch (err) {
                error.BrokenPipe => error.BrokenPipe,
                error.ConnectionResetByPeer => error.ConnectionResetByPeer,
                error.MessageTooLarge => error.MessageTooLarge,
                else => error.Unexpected,
            };
            try self.fire(completion, .{ .udp_send_to = .{
                .socket = state.socket,
                .buffer = state.buffer,
                .result = result,
            } });
            return;
        };
        std.debug.assert(sent == bytes.len);
        try self.fire(completion, .{ .udp_send_to = .{
            .socket = state.socket,
            .buffer = state.buffer,
            .result = sent,
        } });
    }

    fn fire(self: *Loop, completion: *Completion, result: Result) time.ClockError!void {
        const callback = completion.callback orelse return;
        self.deactivate(completion);
        const action = callback(completion.userdata, self, completion, result);
        if (action == .rearm) {
            switch (completion.op) {
                .timer => |*timer| timer.deadline = try self.rearmDeadline(timer.*),
                else => {},
            }
            self.activate(completion);
        }
    }

    fn readInstant(self: *Loop) time.ClockError!time.AwakeInstant {
        const current = try self.awake_clock.now();
        if (self.last_instant) |previous| _ = try current.elapsedSince(previous);
        self.last_instant = current;
        return current;
    }

    fn rearmDeadline(self: *Loop, timer: TimerState) time.ClockError!time.AwakeInstant {
        const repeat = timer.repeat orelse @panic("sys.event timer rearm needs a repeat policy");
        const now = try self.readInstant();
        const interval = switch (repeat) {
            .fixed_delay, .fixed_rate => |value| value,
        };
        const deadline = switch (repeat) {
            .fixed_delay => now.deadlineAfter(interval),
            .fixed_rate => fixedRateDeadline(timer.deadline, now, interval),
        };
        if (!interval.isZero() and now.reached(deadline)) return error.ClockOverflow;
        return deadline;
    }
};

pub const Async = struct {
    read_fd: fd.Descriptor,
    write_fd: fd.Descriptor,

    pub const WaitError: type = ReadError;

    pub fn init() !Async {
        const pipe_fds = try fd.pipeWithOptions(.{ .close_on_exec = true, .nonblocking = true });
        return .{ .read_fd = pipe_fds[0], .write_fd = pipe_fds[1] };
    }

    pub fn deinit(self: *Async) void {
        fd.close(self.read_fd);
        fd.close(self.write_fd);
        self.* = undefined;
    }

    pub fn wait(
        self: Async,
        loop: *Loop,
        completion: *Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            loop: *Loop,
            completion: *Completion,
            result: WaitError!void,
        ) CallbackAction,
    ) void {
        loop.arm(
            completion,
            .{ .async_wait = self },
            userdata,
            AsyncWaitCallback(Userdata, cb).callback,
        );
    }

    pub fn notify(self: Async) !void {
        _ = fd.write(self.write_fd, &.{1}) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
    }

    fn drain(self: Async) void {
        var buffer: [64]u8 = undefined;
        while (true) {
            _ = fd.read(self.read_fd, &buffer) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return,
            };
        }
    }
};

pub const Timer = struct {
    pub const delayed_tick_slots_max: u8 = 1;

    pub const RunError = error{
        Canceled,
        Unexpected,
    };

    pub const Repeat = union(enum) {
        fixed_delay: time.Duration,
        fixed_rate: time.Duration,
    };

    pub const Schedule = struct {
        after: time.Duration,
        repeat: ?Repeat = null,
    };

    pub fn init() !Timer {
        return .{};
    }

    pub fn deinit(self: *Timer) void {
        self.* = undefined;
    }

    pub fn run(
        self: Timer,
        loop: *Loop,
        completion: *Completion,
        schedule: Schedule,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            loop: *Loop,
            completion: *Completion,
            result: RunError!void,
        ) CallbackAction,
    ) time.ClockError!void {
        _ = self;
        if (schedule.repeat) |repeat| switch (repeat) {
            .fixed_delay => {},
            .fixed_rate => |interval| std.debug.assert(!interval.isZero()),
        };
        const now = try loop.readInstant();
        loop.arm(
            completion,
            .{ .timer = .{
                .deadline = now.deadlineAfter(schedule.after),
                .repeat = schedule.repeat,
            } },
            userdata,
            TimerRunCallback(Userdata, cb).callback,
        );
    }
};

pub const TCP = struct {
    fd: net.Socket,

    pub fn initFd(socket_fd: anytype) TCP {
        return .{ .fd = @intCast(socket_fd) };
    }

    pub fn accept(
        self: TCP,
        loop: *Loop,
        completion: *Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            loop: *Loop,
            completion: *Completion,
            result: AcceptError!TCP,
        ) CallbackAction,
    ) void {
        loop.arm(
            completion,
            .{ .tcp_accept = self },
            userdata,
            TcpAcceptCallback(Userdata, cb).callback,
        );
    }

    pub fn read(
        self: TCP,
        loop: *Loop,
        completion: *Completion,
        buffer: ReadBuffer,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            loop: *Loop,
            completion: *Completion,
            socket: TCP,
            buffer: ReadBuffer,
            result: ReadError!usize,
        ) CallbackAction,
    ) void {
        loop.arm(
            completion,
            .{ .tcp_read = .{ .socket = self, .buffer = buffer } },
            userdata,
            TcpReadCallback(Userdata, cb).callback,
        );
    }

    pub fn write(
        self: TCP,
        loop: *Loop,
        completion: *Completion,
        buffer: WriteBuffer,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            loop: *Loop,
            completion: *Completion,
            socket: TCP,
            buffer: WriteBuffer,
            result: WriteError!usize,
        ) CallbackAction,
    ) void {
        loop.arm(
            completion,
            .{ .tcp_write = .{ .socket = self, .buffer = buffer } },
            userdata,
            TcpWriteCallback(Userdata, cb).callback,
        );
    }

    pub fn close(
        self: TCP,
        loop: *Loop,
        completion: *Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            loop: *Loop,
            completion: *Completion,
            socket: TCP,
            result: CloseError!void,
        ) CallbackAction,
    ) void {
        loop.deactivateDescriptor(self.fd);
        loop.deactivate(completion);
        net.close(self.fd);
        completion.* = .{
            .userdata = userdata,
            .callback = TcpCloseCallback(Userdata, cb).callback,
        };
        loop.fire(
            completion,
            .{ .tcp_close = .{ .socket = self, .result = {} } },
        ) catch unreachable;
    }
};

pub const UDP = struct {
    fd: net.Socket,

    pub const BindError = net.SocketError || net.BindError;

    pub fn initFd(socket_fd: anytype) UDP {
        return .{ .fd = @intCast(socket_fd) };
    }

    pub fn bind(address: net.IpAddress) BindError!UDP {
        const socket_fd = try net.udpDatagramSocketForAddress(address, .{
            .close_on_exec = true,
            .nonblocking = true,
        });
        errdefer net.close(socket_fd);
        try net.bindIpAddress(socket_fd, address);
        return initFd(socket_fd);
    }

    pub fn recvFrom(
        self: UDP,
        loop: *Loop,
        completion: *Completion,
        buffer: ReadBuffer,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            loop: *Loop,
            completion: *Completion,
            socket: UDP,
            buffer: ReadBuffer,
            result: RecvError!Datagram,
        ) CallbackAction,
    ) void {
        std.debug.assert(readBufferLength(buffer) > 0);
        loop.arm(
            completion,
            .{ .udp_recv_from = .{ .socket = self, .buffer = buffer } },
            userdata,
            UdpRecvFromCallback(Userdata, cb).callback,
        );
    }

    pub fn sendTo(
        self: UDP,
        loop: *Loop,
        completion: *Completion,
        buffer: WriteBuffer,
        address: net.IpAddress,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            loop: *Loop,
            completion: *Completion,
            socket: UDP,
            buffer: WriteBuffer,
            result: SendError!usize,
        ) CallbackAction,
    ) void {
        loop.arm(
            completion,
            .{ .udp_send_to = .{
                .socket = self,
                .buffer = buffer,
                .address = address,
            } },
            userdata,
            UdpSendToCallback(Userdata, cb).callback,
        );
    }

    pub fn close(self: UDP) void {
        net.close(self.fd);
    }
};

pub const File = struct {
    fd: fd.Descriptor,

    pub fn initFd(file_fd: std.Io.File.Handle) File {
        return .{ .fd = file_fd };
    }

    pub fn poll(
        self: File,
        loop: *Loop,
        completion: *Completion,
        event: PollEvent,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            loop: *Loop,
            completion: *Completion,
            file: File,
            result: PollError!PollEvent,
        ) CallbackAction,
    ) void {
        loop.arm(
            completion,
            .{ .file_poll = .{ .file = self, .event = event } },
            userdata,
            FilePollCallback(Userdata, cb).callback,
        );
    }
};

fn acceptSocket(socket: TCP) AcceptError!TCP {
    const accepted = net.acceptNonBlocking(socket.fd) catch |err| switch (err) {
        error.WouldBlock => return error.Again,
        else => return error.Unexpected,
    };
    return TCP.initFd(accepted);
}

fn readSocket(state: *TcpReadState) ReadError!usize {
    const buffer = readSlice(&state.buffer);
    if (buffer.len == 0) return 0;
    const count = net.recv(state.socket.fd, buffer, 0) catch |err| switch (err) {
        error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
        else => return error.Unexpected,
    };
    if (count == 0) return error.EOF;
    return count;
}

fn writeSocket(state: *const TcpWriteState) WriteError!usize {
    return net.sendNoSignal(state.socket.fd, writeSlice(&state.buffer)) catch |err| switch (err) {
        error.BrokenPipe => error.BrokenPipe,
        error.ConnectionResetByPeer => error.ConnectionResetByPeer,
        else => error.Unexpected,
    };
}

fn readSlice(buffer: *ReadBuffer) []u8 {
    return switch (buffer.*) {
        .slice => |slice| slice,
        .array => |*array| array,
    };
}

fn readBufferLength(buffer: ReadBuffer) usize {
    return switch (buffer) {
        .slice => |slice| slice.len,
        .array => |array| array.len,
    };
}

fn writeSlice(buffer: *const WriteBuffer) []const u8 {
    return switch (buffer.*) {
        .slice => |slice| slice,
        .array => |*array| array.array[0..array.len],
    };
}

fn fixedRateDeadline(
    previous: time.AwakeInstant,
    now: time.AwakeInstant,
    interval: time.Duration,
) time.AwakeInstant {
    std.debug.assert(!interval.isZero());
    const first = previous.deadlineAfter(interval);
    if (!now.reached(first)) return first;
    const late = now.elapsedSince(first) catch unreachable;
    const missed = late.asNanoseconds() / interval.asNanoseconds() +| 1;
    const advance = interval.asNanoseconds() *| missed;
    return first.deadlineAfter(.fromNanoseconds(advance));
}

fn AsyncWaitCallback(
    comptime Userdata: type,
    comptime cb: *const fn (
        ud: ?*Userdata,
        event_loop: *Loop,
        completion: *Completion,
        result: Async.WaitError!void,
    ) CallbackAction,
) type {
    return struct {
        fn callback(
            ud: ?*anyopaque,
            loop: *Loop,
            completion: *Completion,
            result: Result,
        ) CallbackAction {
            return cb(castUserdata(Userdata, ud), loop, completion, result.async_wait);
        }
    };
}

fn TimerRunCallback(
    comptime Userdata: type,
    comptime cb: *const fn (
        ud: ?*Userdata,
        event_loop: *Loop,
        completion: *Completion,
        result: Timer.RunError!void,
    ) CallbackAction,
) type {
    return struct {
        fn callback(
            ud: ?*anyopaque,
            loop: *Loop,
            completion: *Completion,
            result: Result,
        ) CallbackAction {
            return cb(castUserdata(Userdata, ud), loop, completion, result.timer);
        }
    };
}

fn TcpAcceptCallback(
    comptime Userdata: type,
    comptime cb: *const fn (
        ud: ?*Userdata,
        event_loop: *Loop,
        completion: *Completion,
        result: AcceptError!TCP,
    ) CallbackAction,
) type {
    return struct {
        fn callback(
            ud: ?*anyopaque,
            loop: *Loop,
            completion: *Completion,
            result: Result,
        ) CallbackAction {
            return cb(castUserdata(Userdata, ud), loop, completion, result.tcp_accept);
        }
    };
}

fn TcpReadCallback(
    comptime Userdata: type,
    comptime cb: *const fn (
        ud: ?*Userdata,
        event_loop: *Loop,
        completion: *Completion,
        socket: TCP,
        buffer: ReadBuffer,
        result: ReadError!usize,
    ) CallbackAction,
) type {
    return struct {
        fn callback(
            ud: ?*anyopaque,
            loop: *Loop,
            completion: *Completion,
            result: Result,
        ) CallbackAction {
            const read = result.tcp_read;
            return cb(castUserdata(Userdata, ud), loop, completion, read.socket, read.buffer, read.result);
        }
    };
}

fn TcpWriteCallback(
    comptime Userdata: type,
    comptime cb: *const fn (
        ud: ?*Userdata,
        event_loop: *Loop,
        completion: *Completion,
        socket: TCP,
        buffer: WriteBuffer,
        result: WriteError!usize,
    ) CallbackAction,
) type {
    return struct {
        fn callback(
            ud: ?*anyopaque,
            loop: *Loop,
            completion: *Completion,
            result: Result,
        ) CallbackAction {
            const write = result.tcp_write;
            return cb(castUserdata(Userdata, ud), loop, completion, write.socket, write.buffer, write.result);
        }
    };
}

fn UdpRecvFromCallback(
    comptime Userdata: type,
    comptime cb: *const fn (
        ud: ?*Userdata,
        event_loop: *Loop,
        completion: *Completion,
        socket: UDP,
        buffer: ReadBuffer,
        result: RecvError!Datagram,
    ) CallbackAction,
) type {
    return struct {
        fn callback(
            ud: ?*anyopaque,
            loop: *Loop,
            completion: *Completion,
            result: Result,
        ) CallbackAction {
            const received = result.udp_recv_from;
            return cb(
                castUserdata(Userdata, ud),
                loop,
                completion,
                received.socket,
                received.buffer,
                received.result,
            );
        }
    };
}

fn UdpSendToCallback(
    comptime Userdata: type,
    comptime cb: *const fn (
        ud: ?*Userdata,
        event_loop: *Loop,
        completion: *Completion,
        socket: UDP,
        buffer: WriteBuffer,
        result: SendError!usize,
    ) CallbackAction,
) type {
    return struct {
        fn callback(
            ud: ?*anyopaque,
            loop: *Loop,
            completion: *Completion,
            result: Result,
        ) CallbackAction {
            const sent = result.udp_send_to;
            return cb(
                castUserdata(Userdata, ud),
                loop,
                completion,
                sent.socket,
                sent.buffer,
                sent.result,
            );
        }
    };
}

fn TcpCloseCallback(
    comptime Userdata: type,
    comptime cb: *const fn (
        ud: ?*Userdata,
        event_loop: *Loop,
        completion: *Completion,
        socket: TCP,
        result: CloseError!void,
    ) CallbackAction,
) type {
    return struct {
        fn callback(
            ud: ?*anyopaque,
            loop: *Loop,
            completion: *Completion,
            result: Result,
        ) CallbackAction {
            const close = result.tcp_close;
            return cb(castUserdata(Userdata, ud), loop, completion, close.socket, close.result);
        }
    };
}

fn FilePollCallback(
    comptime Userdata: type,
    comptime cb: *const fn (
        ud: ?*Userdata,
        event_loop: *Loop,
        completion: *Completion,
        file: File,
        result: PollError!PollEvent,
    ) CallbackAction,
) type {
    return struct {
        fn callback(
            ud: ?*anyopaque,
            loop: *Loop,
            completion: *Completion,
            result: Result,
        ) CallbackAction {
            const poll = result.file_poll;
            return cb(castUserdata(Userdata, ud), loop, completion, poll.file, poll.result);
        }
    };
}

fn castUserdata(comptime Userdata: type, userdata: ?*anyopaque) ?*Userdata {
    if (Userdata == void) return null;
    return if (userdata) |ptr| @ptrCast(@alignCast(ptr)) else null;
}

fn timer_test_callback(
    state: ?*bool,
    _: *Loop,
    _: *Completion,
    result: Timer.RunError!void,
) CallbackAction {
    _ = result catch return .disarm;
    state.?.* = true;
    return .disarm;
}

const TimerCount = struct {
    hits: usize = 0,
};

const TimerOrder = struct {
    id: u8,
    log: *[2]u8,
    count: *u8,
};

fn timer_order_callback(
    state: ?*TimerOrder,
    _: *Loop,
    _: *Completion,
    result: Timer.RunError!void,
) CallbackAction {
    _ = result catch return .disarm;
    const order = state.?;
    order.log[order.count.*] = order.id;
    order.count.* += 1;
    return .disarm;
}

const TimerRearmState = struct {
    clock: *time.FakeClock,
    late: time.Duration,
    hits: u8 = 0,
};

fn timer_rearm_callback(
    state: ?*TimerRearmState,
    _: *Loop,
    _: *Completion,
    result: Timer.RunError!void,
) CallbackAction {
    _ = result catch return .disarm;
    const rearm = state.?;
    rearm.hits += 1;
    if (rearm.hits != 1) return .disarm;
    rearm.clock.advance(rearm.late);
    return .rearm;
}

fn timer_count_callback(
    state: ?*TimerCount,
    _: *Loop,
    _: *Completion,
    result: Timer.RunError!void,
) CallbackAction {
    _ = result catch return .disarm;
    state.?.hits += 1;
    return .disarm;
}

const ReadResultState = struct {
    hits: usize = 0,
    count: ?usize = null,
    err: ?ReadError = null,
};

fn read_result_callback(
    state: ?*ReadResultState,
    _: *Loop,
    _: *Completion,
    _: TCP,
    _: ReadBuffer,
    result: ReadError!usize,
) CallbackAction {
    const read_state = state.?;
    read_state.hits += 1;
    if (result) |count| {
        read_state.count = count;
    } else |err| {
        read_state.err = err;
    }
    return .disarm;
}

const AcceptResultState = struct {
    hits: usize = 0,
    accepted: ?TCP = null,
    err: ?AcceptError = null,
};

fn accept_result_callback(
    state: ?*AcceptResultState,
    _: *Loop,
    _: *Completion,
    result: AcceptError!TCP,
) CallbackAction {
    const accept_state = state.?;
    accept_state.hits += 1;
    if (result) |accepted| {
        accept_state.accepted = accepted;
    } else |err| {
        accept_state.err = err;
    }
    return .disarm;
}

const CloseResultState = struct {
    hits: usize = 0,
    err: ?CloseError = null,
};

fn close_result_callback(
    state: ?*CloseResultState,
    _: *Loop,
    _: *Completion,
    _: TCP,
    result: CloseError!void,
) CallbackAction {
    const close_state = state.?;
    close_state.hits += 1;
    _ = result catch |err| {
        close_state.err = err;
    };
    return .disarm;
}

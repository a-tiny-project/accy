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

pub const Completion = struct {
    active: bool = false,
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
    poll_completions: []*Completion,

    pub fn init(options: Options) !Loop {
        const allocator = options.allocator;
        const count: usize = @intCast(options.entries);
        const entries = try allocator.alloc(?*Completion, count);
        errdefer allocator.free(entries);
        @memset(entries, null);

        const pollfds = try allocator.alloc(descriptor_poll.Descriptor, count);
        errdefer allocator.free(pollfds);

        const poll_completions = try allocator.alloc(*Completion, count);
        errdefer allocator.free(poll_completions);

        return .{
            .allocator = allocator,
            .awake_clock = options.awake_clock,
            .last_instant = null,
            .entries = entries,
            .pollfds = pollfds,
            .poll_completions = poll_completions,
        };
    }

    pub fn deinit(self: *Loop) void {
        self.allocator.free(self.poll_completions);
        self.allocator.free(self.pollfds);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn run(self: *Loop, mode: RunMode) !void {
        while (self.hasActive()) {
            const now = try self.readInstant();
            if (try self.fireDueTimer(now)) {
                if (mode != .until_done) return;
                continue;
            }

            const poll_count = self.preparePoll();
            const timeout_ms = self.timeoutMillis(mode, now);
            if (poll_count == 0) {
                if (timeout_ms < 0) return;
                if (timeout_ms > 0) {
                    const timeout_ns = @as(u64, @intCast(timeout_ms)) *
                        std.time.ns_per_ms;
                    std.Io.sleep(
                        std.Options.debug_io,
                        .fromNanoseconds(timeout_ns),
                        .awake,
                    ) catch {};
                }
                if (mode != .until_done) return;
                continue;
            }

            const ready = descriptor_poll.wait(self.pollfds[0..poll_count], timeout_ms) catch
                return error.Unexpected;
            if (ready == 0) {
                if (mode != .until_done) return;
                continue;
            }

            _ = try self.readInstant();
            if (try self.fireFirstReady(poll_count) and mode != .until_done) return;
            if (mode == .no_wait) return;
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
            for (self.entries) |slot| {
                if (slot == completion) return;
            }
            @panic("sys.event active completion belongs to another loop");
        }
        for (self.entries) |*slot| {
            if (slot.* == null) {
                slot.* = completion;
                completion.active = true;
                return;
            }
        }
        @panic("sys.event loop completion capacity exhausted");
    }

    fn arm(
        self: *Loop,
        completion: *Completion,
        op: Operation,
        userdata: ?*anyopaque,
        callback: Callback,
    ) void {
        var replacement: Completion = .{
            .op = op,
            .userdata = userdata,
            .callback = callback,
        };
        if (completion.active) {
            for (self.entries) |slot| {
                if (slot == completion) {
                    replacement.active = true;
                    completion.* = replacement;
                    return;
                }
            }
            @panic("sys.event active completion belongs to another loop");
        }
        completion.* = replacement;
        self.activate(completion);
    }

    fn deactivate(self: *Loop, completion: *Completion) void {
        if (!completion.active) return;
        for (self.entries) |*slot| {
            if (slot.* == completion) {
                slot.* = null;
                completion.active = false;
                return;
            }
        }
        @panic("sys.event active completion belongs to another loop");
    }

    fn deactivateDescriptor(self: *Loop, descriptor: fd.Descriptor) void {
        for (self.entries) |*slot| {
            const completion = slot.* orelse continue;
            if (completion.op.descriptor()) |active_descriptor| {
                if (active_descriptor == descriptor) {
                    completion.active = false;
                    slot.* = null;
                }
            }
        }
    }

    fn hasActive(self: *Loop) bool {
        for (self.entries) |slot| {
            if (slot != null) return true;
        }
        return false;
    }

    fn preparePoll(self: *Loop) usize {
        var count: usize = 0;
        for (self.entries) |slot| {
            const completion = slot orelse continue;
            const descriptor = completion.op.descriptor() orelse continue;
            self.pollfds[count] = .{
                .fd = descriptor,
                .events = completion.op.events(),
                .revents = 0,
            };
            self.poll_completions[count] = completion;
            count += 1;
        }
        return count;
    }

    fn timeoutMillis(self: *Loop, mode: RunMode, now: time.AwakeInstant) i32 {
        if (mode == .no_wait) return 0;
        var best: ?u64 = null;
        for (self.entries) |slot| {
            const completion = slot orelse continue;
            switch (completion.op) {
                .timer => |timer| {
                    const remaining = now.remainingUntil(timer.deadline).asMillisecondsCeil();
                    best = if (best) |current| @min(current, remaining) else remaining;
                },
                else => {},
            }
        }
        const value = best orelse return -1;
        return @intCast(@min(value, std.math.maxInt(i32)));
    }

    fn fireDueTimer(self: *Loop, now: time.AwakeInstant) time.ClockError!bool {
        var due: ?*Completion = null;
        for (self.entries) |slot| {
            const completion = slot orelse continue;
            switch (completion.op) {
                .timer => |timer| {
                    if (!now.reached(timer.deadline)) continue;
                    const current = due orelse {
                        due = completion;
                        continue;
                    };
                    const current_timer = switch (current.op) {
                        .timer => |value| value,
                        else => unreachable,
                    };
                    if (timer.deadline.isBefore(current_timer.deadline)) due = completion;
                },
                else => {},
            }
        }
        const completion = due orelse return false;
        try self.fire(completion, .{ .timer = {} });
        return true;
    }

    fn fireFirstReady(self: *Loop, count: usize) time.ClockError!bool {
        var index: usize = 0;
        while (index < count) : (index += 1) {
            if (self.pollfds[index].revents == 0) continue;
            const completion = self.poll_completions[index];
            if (!completion.active) continue;
            try self.fireReady(completion);
            return true;
        }
        return false;
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

test "event loop timer uses owned sys event types" {
    var loop = try Loop.init(.{ .allocator = std.testing.allocator });
    defer loop.deinit();

    var timer = try Timer.init();
    defer timer.deinit();

    var completion: Completion = .{};
    var fired = false;
    try timer.run(
        &loop,
        &completion,
        .{ .after = .zero },
        bool,
        &fired,
        timer_test_callback,
    );

    try loop.run(.until_done);
    try std.testing.expect(fired);
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

test "event loop replaces an active completion without consuming another entry" {
    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 1 });
    defer loop.deinit();

    var timer = try Timer.init();
    defer timer.deinit();
    var completion: Completion = .{};
    var first: TimerCount = .{};
    var second: TimerCount = .{};
    try timer.run(
        &loop,
        &completion,
        .{ .after = .zero },
        TimerCount,
        &first,
        timer_count_callback,
    );
    try timer.run(
        &loop,
        &completion,
        .{ .after = .zero },
        TimerCount,
        &second,
        timer_count_callback,
    );

    try loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 0), first.hits);
    try std.testing.expectEqual(@as(usize, 1), second.hits);
    try std.testing.expect(!completion.active);
}

test "event loop disarm releases an active completion" {
    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 1 });
    defer loop.deinit();
    var timer = try Timer.init();
    defer timer.deinit();
    var completion: Completion = .{};
    var state: TimerCount = .{};
    try timer.run(
        &loop,
        &completion,
        .{ .after = .fromMilliseconds(std.math.maxInt(u64)) },
        TimerCount,
        &state,
        timer_count_callback,
    );
    try std.testing.expect(completion.active);

    loop.disarm(&completion);
    try std.testing.expect(!completion.active);
    try timer.run(
        &loop,
        &completion,
        .{ .after = .zero },
        TimerCount,
        &state,
        timer_count_callback,
    );
    try loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 1), state.hits);
}

test "event loop fake clock orders and delays timers" {
    var fake = time.FakeClock.zero();
    var loop = try Loop.init(.{
        .allocator = std.testing.allocator,
        .entries = 2,
        .awake_clock = fake.awakeClock(),
    });
    defer loop.deinit();
    var timer = try Timer.init();
    defer timer.deinit();
    var completions: [2]Completion = @splat(.{});
    var log: [2]u8 = undefined;
    var count: u8 = 0;
    var late = TimerOrder{ .id = 2, .log = &log, .count = &count };
    var early = TimerOrder{ .id = 1, .log = &log, .count = &count };
    try timer.run(
        &loop,
        &completions[0],
        .{ .after = .fromMilliseconds(2) },
        TimerOrder,
        &late,
        timer_order_callback,
    );
    try timer.run(
        &loop,
        &completions[1],
        .{ .after = .fromMilliseconds(1) },
        TimerOrder,
        &early,
        timer_order_callback,
    );
    try loop.run(.no_wait);
    try std.testing.expectEqual(@as(u8, 0), count);
    fake.advance(.fromMilliseconds(2));
    try loop.run(.once);
    try loop.run(.once);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &log);
}

test "event loop fake clock cancellation prevents a delayed timer" {
    var fake = time.FakeClock.zero();
    var loop = try Loop.init(.{
        .allocator = std.testing.allocator,
        .entries = 1,
        .awake_clock = fake.awakeClock(),
    });
    defer loop.deinit();
    var timer = try Timer.init();
    defer timer.deinit();
    var completion: Completion = .{};
    var state: TimerCount = .{};
    try timer.run(
        &loop,
        &completion,
        .{ .after = .fromMilliseconds(1) },
        TimerCount,
        &state,
        timer_count_callback,
    );
    loop.disarm(&completion);
    fake.advance(.fromMilliseconds(1));
    try loop.run(.no_wait);
    try std.testing.expectEqual(@as(usize, 0), state.hits);
}

test "event loop fixed rate skips delayed ticks within one slot" {
    var fake = time.FakeClock.zero();
    var loop = try Loop.init(.{
        .allocator = std.testing.allocator,
        .entries = 1,
        .awake_clock = fake.awakeClock(),
    });
    defer loop.deinit();
    var timer = try Timer.init();
    defer timer.deinit();
    var completion: Completion = .{};
    var state = TimerRearmState{ .clock = &fake, .late = .fromMilliseconds(25) };
    const interval = time.Duration.fromMilliseconds(10);
    try timer.run(
        &loop,
        &completion,
        .{ .after = interval, .repeat = .{ .fixed_rate = interval } },
        TimerRearmState,
        &state,
        timer_rearm_callback,
    );
    fake.advance(interval);
    try loop.run(.once);
    try std.testing.expectEqual(@as(u8, 1), state.hits);
    try std.testing.expectEqual(@as(u8, 1), Timer.delayed_tick_slots_max);
    try loop.run(.no_wait);
    try std.testing.expectEqual(@as(u8, 1), state.hits);
    fake.advance(.fromMilliseconds(5));
    try loop.run(.once);
    try std.testing.expectEqual(@as(u8, 2), state.hits);
}

test "event loop fixed delay starts after a late callback" {
    var fake = time.FakeClock.zero();
    var loop = try Loop.init(.{
        .allocator = std.testing.allocator,
        .entries = 1,
        .awake_clock = fake.awakeClock(),
    });
    defer loop.deinit();
    var timer = try Timer.init();
    defer timer.deinit();
    var completion: Completion = .{};
    var state = TimerRearmState{ .clock = &fake, .late = .fromMilliseconds(25) };
    const interval = time.Duration.fromMilliseconds(10);
    try timer.run(
        &loop,
        &completion,
        .{ .after = interval, .repeat = .{ .fixed_delay = interval } },
        TimerRearmState,
        &state,
        timer_rearm_callback,
    );
    fake.advance(interval);
    try loop.run(.once);
    fake.advance(.fromMilliseconds(9));
    try loop.run(.no_wait);
    try std.testing.expectEqual(@as(u8, 1), state.hits);
    fake.advance(.fromMilliseconds(1));
    try loop.run(.once);
    try std.testing.expectEqual(@as(u8, 2), state.hits);
}

test "event loop rejects an awake clock regression" {
    var fake = time.FakeClock.zero();
    fake.advance(.fromMilliseconds(2));
    var loop = try Loop.init(.{
        .allocator = std.testing.allocator,
        .entries = 1,
        .awake_clock = fake.awakeClock(),
    });
    defer loop.deinit();
    var timer = try Timer.init();
    defer timer.deinit();
    var completion: Completion = .{};
    var state: TimerCount = .{};
    try timer.run(
        &loop,
        &completion,
        .{ .after = .fromMilliseconds(1) },
        TimerCount,
        &state,
        timer_count_callback,
    );
    fake.regress(.fromMilliseconds(1));
    try std.testing.expectError(error.ClockRegressed, loop.run(.no_wait));
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

test "event TCP read reports peer shutdown as EOF" {
    const sockets = net.socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer net.close(sockets[0]);
    net.close(sockets[1]);

    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 1 });
    defer loop.deinit();
    var completion: Completion = .{};
    var state: ReadResultState = .{};
    var buffer: [1]u8 = undefined;
    TCP.initFd(sockets[0]).read(
        &loop,
        &completion,
        .{ .slice = &buffer },
        ReadResultState,
        &state,
        read_result_callback,
    );

    try loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expectEqual(@as(?usize, null), state.count);
    try std.testing.expectEqual(@as(?ReadError, error.EOF), state.err);
    try std.testing.expect(!completion.active);
}

test "event TCP zero-length read preserves a ready byte" {
    const sockets = net.socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer net.close(sockets[0]);
    defer net.close(sockets[1]);
    try std.testing.expectEqual(@as(usize, 1), try net.sendNoSignal(sockets[0], "x"));

    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 1 });
    defer loop.deinit();
    var completion: Completion = .{};
    var state: ReadResultState = .{};
    var buffer: [1]u8 = undefined;
    TCP.initFd(sockets[1]).read(
        &loop,
        &completion,
        .{ .slice = buffer[0..0] },
        ReadResultState,
        &state,
        read_result_callback,
    );

    try loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 1), state.hits);
    try std.testing.expectEqual(@as(?usize, 0), state.count);
    try std.testing.expectEqual(@as(?ReadError, null), state.err);
    try std.testing.expectEqual(@as(usize, 1), try net.recv(sockets[1], &buffer, 0));
    try std.testing.expectEqual(@as(u8, 'x'), buffer[0]);
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

test "event TCP accepts and closes a loopback connection" {
    const listener = net.tcpStreamSocket(.{
        .close_on_exec = true,
        .nonblocking = true,
    }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer net.close(listener);
    try net.bindIp4(listener, net.ip4Address(.{ 127, 0, 0, 1 }, 0));
    try net.listen(listener, 1);
    const port = try net.socketPort(listener);

    const client = try net.tcpStreamSocket(.{ .close_on_exec = true });
    defer net.close(client);
    try net.connectIp4(client, net.ip4Address(.{ 127, 0, 0, 1 }, port));

    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 1 });
    defer loop.deinit();
    var completion: Completion = .{};
    var accept_state: AcceptResultState = .{};
    TCP.initFd(listener).accept(
        &loop,
        &completion,
        AcceptResultState,
        &accept_state,
        accept_result_callback,
    );
    try loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 1), accept_state.hits);
    try std.testing.expectEqual(@as(?AcceptError, null), accept_state.err);
    const accepted = accept_state.accepted orelse return error.MissingAcceptedSocket;
    var accepted_open = true;
    defer if (accepted_open) net.close(accepted.fd);

    var close_state: CloseResultState = .{};
    accepted.close(
        &loop,
        &completion,
        CloseResultState,
        &close_state,
        close_result_callback,
    );
    accepted_open = false;
    try std.testing.expectEqual(@as(usize, 1), close_state.hits);
    try std.testing.expectEqual(@as(?CloseError, null), close_state.err);
    try std.testing.expect(!completion.active);
}

test "event TCP close replaces an unrelated active completion" {
    const sockets = net.socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    var first_open = true;
    defer if (first_open) net.close(sockets[0]);
    defer net.close(sockets[1]);

    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 1 });
    defer loop.deinit();
    var timer = try Timer.init();
    defer timer.deinit();
    var completion: Completion = .{};
    var timer_state: TimerCount = .{};
    try timer.run(
        &loop,
        &completion,
        .{ .after = .fromMilliseconds(std.math.maxInt(u64)) },
        TimerCount,
        &timer_state,
        timer_count_callback,
    );

    var close_state: CloseResultState = .{};
    TCP.initFd(sockets[0]).close(
        &loop,
        &completion,
        CloseResultState,
        &close_state,
        close_result_callback,
    );
    first_open = false;
    try std.testing.expectEqual(@as(usize, 0), timer_state.hits);
    try std.testing.expectEqual(@as(usize, 1), close_state.hits);
    try std.testing.expect(!completion.active);
    try std.testing.expect(!loop.hasActive());
}

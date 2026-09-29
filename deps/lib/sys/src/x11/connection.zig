const std = @import("std");
const sys = @import("../root.zig");
const auth = @import("auth.zig");
const display = @import("display.zig");
const protocol = @import("protocol.zig");

const env = sys.env;
const net = sys.net;

pub const Message = [protocol.message_length]u8;

const message_bytes = @sizeOf(Message);
pub const minimum_reply_byte_count = 0;
pub const default_reply_byte_count = 1 << 20;

pub const Limits = struct {
    retained_message_count: usize = 256,
    request_byte_count: usize = protocol.maximum_request_byte_count,
    reply_byte_count: usize = default_reply_byte_count,
};

pub const CapacityError = error{
    RetainedMessagesEmpty,
    RequestStorageTooSmall,
    RequestStorageTooLarge,
    RequestStorageUnaligned,
    ReplyStorageTooSmall,
    ReplyStorageTooLarge,
    ReplyStorageUnaligned,
    CapacityOverflow,
};

pub const Capacity = struct {
    retained_message_count: usize,
    retained_message_bytes: usize,
    request_byte_count: usize,
    reply_byte_count: usize,
    initialization_scratch_byte_count: usize,
    steady_requested_bytes: usize,
    initialization_high_water_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.retained_message_count == 0) return error.RetainedMessagesEmpty;
        if (limits.request_byte_count < protocol.minimum_request_byte_count) {
            return error.RequestStorageTooSmall;
        }
        if (limits.request_byte_count > protocol.maximum_request_byte_count) {
            return error.RequestStorageTooLarge;
        }
        if (limits.request_byte_count % 4 != 0) return error.RequestStorageUnaligned;
        if (@as(u64, @intCast(limits.reply_byte_count)) >
            protocol.maximum_reply_extra_byte_count)
        {
            return error.ReplyStorageTooLarge;
        }
        if (limits.reply_byte_count % 4 != 0) return error.ReplyStorageUnaligned;
        const retained_message_bytes = std.math.mul(
            usize,
            limits.retained_message_count,
            message_bytes,
        ) catch return error.CapacityOverflow;
        const initialization_scratch_byte_count = @max(
            auth.maximum_authority_file_byte_count,
            protocol.maximum_setup_response_byte_count,
        );
        const retained_and_request_bytes = std.math.add(
            usize,
            retained_message_bytes,
            limits.request_byte_count,
        ) catch return error.CapacityOverflow;
        const steady_requested_bytes = std.math.add(
            usize,
            retained_and_request_bytes,
            limits.reply_byte_count,
        ) catch return error.CapacityOverflow;
        const initialization_high_water_bytes = std.math.add(
            usize,
            steady_requested_bytes,
            initialization_scratch_byte_count,
        ) catch return error.CapacityOverflow;
        std.debug.assert(
            retained_message_bytes / message_bytes == limits.retained_message_count,
        );
        return .{
            .retained_message_count = limits.retained_message_count,
            .retained_message_bytes = retained_message_bytes,
            .request_byte_count = limits.request_byte_count,
            .reply_byte_count = limits.reply_byte_count,
            .initialization_scratch_byte_count = initialization_scratch_byte_count,
            .steady_requested_bytes = steady_requested_bytes,
            .initialization_high_water_bytes = initialization_high_water_bytes,
        };
    }
};

pub const Status = struct {
    retained_message_capacity_rejection_count: u64 = 0,
    request_capacity_rejection_count: u64 = 0,
    reply_capacity_rejection_count: u64 = 0,
};

pub const RetainError = error{
    RetainedMessageCapacityExceeded,
};

const RetainedMessages = struct {
    allocator: std.mem.Allocator,
    items: []Message,
    head: usize = 0,
    count: usize = 0,
    rejection_count: u64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!RetainedMessages {
        std.debug.assert(capacity.retained_message_count > 0);
        std.debug.assert(capacity.retained_message_bytes % message_bytes == 0);
        std.debug.assert(
            capacity.retained_message_bytes / message_bytes ==
                capacity.retained_message_count,
        );
        return .{
            .allocator = allocator,
            .items = try allocator.alloc(Message, capacity.retained_message_count),
        };
    }

    fn deinit(self: *RetainedMessages) void {
        std.debug.assert(self.count <= self.items.len);
        self.allocator.free(self.items);
        self.* = undefined;
    }

    fn append(self: *RetainedMessages, message: Message) RetainError!void {
        std.debug.assert(self.count <= self.items.len);
        if (self.count == self.items.len) {
            self.rejection_count +|= 1;
            return error.RetainedMessageCapacityExceeded;
        }
        const index = (self.head + self.count) % self.items.len;
        self.items[index] = message;
        self.count += 1;
    }

    fn pop(self: *RetainedMessages) ?Message {
        std.debug.assert(self.count <= self.items.len);
        if (self.count == 0) return null;
        const message = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
        return message;
    }

    fn status(self: *const RetainedMessages) Status {
        std.debug.assert(self.count <= self.items.len);
        return .{
            .retained_message_capacity_rejection_count = self.rejection_count,
        };
    }
};

const Storage = struct {
    allocator: std.mem.Allocator,
    retained_messages: RetainedMessages,
    request: []u8,
    reply: []u8,
    initialization_scratch: []u8,

    fn init(
        allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Storage {
        var retained_messages = try RetainedMessages.init(allocator, capacity);
        errdefer retained_messages.deinit();
        const request = try allocator.alloc(u8, capacity.request_byte_count);
        errdefer allocator.free(request);
        const reply = try allocator.alloc(u8, capacity.reply_byte_count);
        errdefer allocator.free(reply);
        return .{
            .allocator = allocator,
            .retained_messages = retained_messages,
            .request = request,
            .reply = reply,
            .initialization_scratch = try allocator.alloc(
                u8,
                capacity.initialization_scratch_byte_count,
            ),
        };
    }

    fn deinit(self: *Storage) void {
        self.retained_messages.deinit();
        self.allocator.free(self.request);
        self.allocator.free(self.reply);
        if (self.initialization_scratch.len != 0) {
            self.allocator.free(self.initialization_scratch);
        }
        self.* = undefined;
    }

    fn releaseInitializationScratch(self: *Storage) void {
        std.debug.assert(self.initialization_scratch.len > 0);
        self.allocator.free(self.initialization_scratch);
        self.initialization_scratch = &.{};
    }
};

pub const ConnectError = error{
    MissingDisplay,
    RemoteDisplayUnsupported,
    InvalidDisplay,
    ConnectionFailed,
    AuthenticationFailed,
    SetupFailed,
    SetupTruncated,
    NoUsableScreen,
    NoUsableVisual,
    OutOfMemory,
};

pub const IoError = error{
    ConnectionLost,
};

pub const ReplyError = error{
    ConnectionLost,
    RequestFailed,
    UnexpectedReply,
    ReplyCapacityExceeded,
    RetainedMessageCapacityExceeded,
} || protocol.RequestError;

/// Caller-owned state for observing an acquisition reply or failure across
/// retries. At most one acquisition is observed at a time on a connection.
/// `reply_sequence` holds the expected reply's low 16 bits. `request_sequence`
/// and `request_opcode` select the prior request whose error enters `failure`.
pub const ReplyObservation = struct {
    reply_sequence: u16,
    request_sequence: u16,
    request_opcode: u8,
    failure: ?protocol.ErrorPacket = null,
};

pub const ReplyView = struct {
    head: [protocol.message_length]u8,
    extra: []const u8,

    pub fn dataByte(self: *const ReplyView) u8 {
        return self.head[1];
    }

    pub fn u32At(self: *const ReplyView, offset: usize) u32 {
        return std.mem.readInt(u32, self.head[offset..][0..4], .little);
    }

    pub fn u16At(self: *const ReplyView, offset: usize) u16 {
        return std.mem.readInt(u16, self.head[offset..][0..2], .little);
    }
};

fn connectSocket(path: []const u8) !net.Stream {
    if (net.Address.initUnixAbstract(path)) |abstract| {
        if (net.connectStream(abstract)) |stream| return stream else |_| {}
    } else |_| {}
    const filesystem = try net.Address.initUnix(path);
    return net.connectStream(filesystem);
}

pub const Connection = struct {
    allocator: std.mem.Allocator,
    target: display.Target,
    stream: net.Stream,
    setup: protocol.Setup,
    screen: u32,
    next_resource: u32 = 0,
    sent_sequence: u16 = 0,
    retained_messages: RetainedMessages,
    request_storage: []u8,
    request_scratch: protocol.Request,
    reply_storage: []u8,
    receive_head: Message = undefined,
    receive_head_count: usize = 0,
    reply_capacity_rejection_count: u64 = 0,

    pub fn connect(
        allocator: std.mem.Allocator,
        capacity: Capacity,
    ) ConnectError!Connection {
        const target = display.parse(env.get("DISPLAY")) catch |err| switch (err) {
            error.MissingDisplay => return error.MissingDisplay,
            error.RemoteDisplayUnsupported => return error.RemoteDisplayUnsupported,
            error.InvalidDisplay => return error.InvalidDisplay,
        };
        return connectTo(allocator, target, capacity);
    }

    pub fn connectTo(
        allocator: std.mem.Allocator,
        target: display.Target,
        capacity: Capacity,
    ) ConnectError!Connection {
        var storage = Storage.init(allocator, capacity) catch return error.OutOfMemory;
        errdefer storage.deinit();

        var path_buffer: [64]u8 = undefined;
        const path = target.socketPath(&path_buffer) catch return error.InvalidDisplay;

        var stream = connectSocket(path) catch return error.ConnectionFailed;
        errdefer stream.close();

        var setup_request_storage: [protocol.setup_request_byte_count]u8 = undefined;
        var setup_request = protocol.Request.init(
            &setup_request_storage,
            setup_request_storage.len,
        );
        const cookie = auth.loadCookie(storage.initialization_scratch, target.display);
        if (cookie) |found| {
            protocol.setupRequest(&setup_request, auth.cookie_name, &found.data) catch unreachable;
        } else {
            protocol.setupRequest(&setup_request, "", "") catch unreachable;
        }
        stream.writeAll(setup_request.bytes()) catch return error.ConnectionFailed;

        var prefix: [8]u8 = undefined;
        readExact(stream, &prefix) catch return error.ConnectionFailed;
        const status = prefix[0];
        const body_units = std.mem.readInt(u16, prefix[6..8], .little);

        const body_byte_count = @as(usize, body_units) * 4;
        std.debug.assert(body_byte_count <= storage.initialization_scratch.len);
        const body = storage.initialization_scratch[0..body_byte_count];
        readExact(stream, body) catch return error.ConnectionFailed;

        if (status == 0) return error.AuthenticationFailed;
        if (status != 1) return error.SetupFailed;

        const setup = protocol.parseSetup(body, target.screen) catch |err| switch (err) {
            error.SetupFailed => return error.SetupFailed,
            error.SetupTruncated => return error.SetupTruncated,
            error.NoUsableScreen => return error.NoUsableScreen,
            error.NoUsableVisual => return error.NoUsableVisual,
        };
        const server_request_bytes = @as(usize, setup.max_request_units) * 4;
        if (server_request_bytes < protocol.minimum_request_byte_count) {
            return error.SetupFailed;
        }
        const request_byte_count = @min(storage.request.len, server_request_bytes);
        storage.releaseInitializationScratch();

        return .{
            .allocator = allocator,
            .target = target,
            .stream = stream,
            .setup = setup,
            .screen = target.screen,
            .retained_messages = storage.retained_messages,
            .request_storage = storage.request,
            .request_scratch = protocol.Request.init(storage.request, request_byte_count),
            .reply_storage = storage.reply,
        };
    }

    pub fn close(self: *Connection) void {
        self.retained_messages.deinit();
        self.allocator.free(self.request_storage);
        self.allocator.free(self.reply_storage);
        self.stream.close();
    }

    pub fn generateId(self: *Connection) u32 {
        const id = self.setup.resource_id_base | (self.next_resource & self.setup.resource_id_mask);
        self.next_resource += 1;
        return id;
    }

    pub fn maxRequestBytes(self: *const Connection) usize {
        return self.request_scratch.byteCapacity();
    }

    pub fn beginRequest(self: *Connection) *protocol.Request {
        self.request_scratch.reset();
        return &self.request_scratch;
    }

    pub fn sendRequest(self: *Connection) IoError!void {
        const bytes = self.request_scratch.bytes();
        std.debug.assert(bytes.len >= 4);
        std.debug.assert(bytes.len % 4 == 0);
        var count: u16 = 0;
        var offset: usize = 0;
        while (offset < bytes.len) {
            std.debug.assert(bytes.len - offset >= 4);
            const length = @as(usize, std.mem.readInt(u16, bytes[offset + 2 ..][0..2], .little)) * 4;
            std.debug.assert(length >= 4);
            std.debug.assert(length <= bytes.len - offset);
            offset += length;
            count +%= 1;
        }
        self.stream.writeAll(bytes) catch return error.ConnectionLost;
        self.sent_sequence +%= count;
    }

    pub fn nextRequestSequence(self: *const Connection) u16 {
        return self.sent_sequence +% 1;
    }

    pub fn nextMessage(self: *Connection) IoError!?Message {
        if (self.retained_messages.pop()) |message| return message;
        try self.fillHead(false);
        if (self.receive_head_count < protocol.message_length) return null;
        const head = self.receive_head;
        self.receive_head_count = 0;
        return head;
    }

    pub fn retainMessage(self: *Connection, message: Message) RetainError!void {
        try self.retained_messages.append(message);
    }

    pub fn storageStatus(self: *const Connection) Status {
        var status = self.retained_messages.status();
        status.request_capacity_rejection_count =
            self.request_scratch.capacityRejectionCount();
        status.reply_capacity_rejection_count = self.reply_capacity_rejection_count;
        return status;
    }

    pub fn waitReadable(self: *Connection, timeout_ms: i32) IoError!bool {
        return net.pollReadable(self.stream.handle, timeout_ms) catch error.ConnectionLost;
    }

    pub fn waitReply(self: *Connection) ReplyError!ReplyView {
        return self.waitReplyMatching(null);
    }

    /// Blocks until the expected reply arrives, capturing exact sequence and
    /// major-opcode errors while retaining unrelated 32-byte messages. Retention
    /// is bounded by `Capacity.retained_message_count`. On
    /// `RetainedMessageCapacityExceeded`, the earlier queue and blocked head
    /// survive. Drain messages and retry with the same observation. A mismatched
    /// reply has its full payload consumed, then raises `UnexpectedReply`.
    pub fn waitReplyObserved(self: *Connection, observation: *ReplyObservation) ReplyError!ReplyView {
        return self.waitReplyMatching(observation);
    }

    fn waitReplyMatching(self: *Connection, observation: ?*ReplyObservation) ReplyError!ReplyView {
        while (true) {
            try self.fillHead(true);
            const head = self.receive_head;
            const code = head[0] & 0x7F;
            if (code == 1) {
                const extra_units = std.mem.readInt(u32, head[4..8], .little);
                const extra_byte_count = @as(u64, extra_units) * 4;
                self.receive_head_count = 0;
                if (extra_byte_count > self.reply_storage.len) {
                    self.reply_capacity_rejection_count +|= 1;
                    discardExact(self.stream, extra_byte_count) catch
                        return error.ConnectionLost;
                    return error.ReplyCapacityExceeded;
                }
                const extra_len: usize = @intCast(extra_byte_count);
                const extra = self.reply_storage[0..extra_len];
                readExact(self.stream, extra) catch return error.ConnectionLost;
                if (observation) |watched| {
                    if (std.mem.readInt(u16, head[2..4], .little) != watched.reply_sequence) return error.UnexpectedReply;
                }
                return .{ .head = head, .extra = extra };
            }
            if (code == 0) {
                if (observation) |watched| {
                    const failure = protocol.ErrorPacket.decode(&head);
                    if (failure.sequence == watched.request_sequence and failure.major_opcode == watched.request_opcode) {
                        watched.failure = failure;
                        self.receive_head_count = 0;
                        continue;
                    }
                } else {
                    self.receive_head_count = 0;
                    return error.RequestFailed;
                }
            }
            try self.retained_messages.append(head);
            self.receive_head_count = 0;
        }
    }

    fn fillHead(self: *Connection, blocking: bool) IoError!void {
        std.debug.assert(self.receive_head_count <= self.receive_head.len);
        while (self.receive_head_count < self.receive_head.len) {
            if (!blocking) {
                const readable = net.pollReadable(self.stream.handle, 0) catch
                    return error.ConnectionLost;
                if (!readable) return;
            }
            const count = self.stream.read(self.receive_head[self.receive_head_count..]) catch
                return error.ConnectionLost;
            if (count == 0) return error.ConnectionLost;
            self.receive_head_count += count;
        }
    }

    pub fn internAtom(self: *Connection, name: []const u8) ReplyError!u32 {
        const request = self.beginRequest();
        try protocol.internAtom(request, name);
        try self.sendRequest();
        const reply = try self.waitReply();
        return reply.u32At(8);
    }
};

fn readExact(stream: net.Stream, buffer: []u8) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const count = try stream.read(buffer[filled..]);
        if (count == 0) return error.ConnectionLost;
        filled += count;
    }
}

fn discardExact(stream: net.Stream, byte_count: u64) !void {
    std.debug.assert(byte_count <= protocol.maximum_reply_extra_byte_count);
    var scratch: [protocol.reply_discard_scratch_byte_count]u8 = undefined;
    var remaining = byte_count;
    while (remaining > 0) {
        const count: usize = @intCast(@min(remaining, scratch.len));
        try readExact(stream, scratch[0..count]);
        remaining -= count;
    }
}

test "connection capacity derives exact steady and initialization storage" {
    const capacity = try Capacity.derive(.{});
    try std.testing.expectEqual(@as(usize, 256), capacity.retained_message_count);
    try std.testing.expectEqual(256 * message_bytes, capacity.retained_message_bytes);
    try std.testing.expectEqual(
        protocol.maximum_request_byte_count,
        capacity.request_byte_count,
    );
    try std.testing.expectEqual(default_reply_byte_count, capacity.reply_byte_count);
    try std.testing.expectEqual(
        capacity.retained_message_bytes + capacity.request_byte_count + capacity.reply_byte_count,
        capacity.steady_requested_bytes,
    );
    try std.testing.expectEqual(
        @max(
            auth.maximum_authority_file_byte_count,
            protocol.maximum_setup_response_byte_count,
        ),
        capacity.initialization_scratch_byte_count,
    );
    try std.testing.expectEqual(
        capacity.steady_requested_bytes + capacity.initialization_scratch_byte_count,
        capacity.initialization_high_water_bytes,
    );
    try std.testing.expectError(error.RetainedMessagesEmpty, Capacity.derive(.{
        .retained_message_count = 0,
    }));
    try std.testing.expectError(error.RequestStorageTooSmall, Capacity.derive(.{
        .request_byte_count = protocol.minimum_request_byte_count - 4,
    }));
    try std.testing.expectError(error.RequestStorageTooLarge, Capacity.derive(.{
        .request_byte_count = protocol.maximum_request_byte_count + 4,
    }));
    try std.testing.expectError(error.RequestStorageUnaligned, Capacity.derive(.{
        .request_byte_count = protocol.minimum_request_byte_count + 1,
    }));
    try std.testing.expectEqual(
        minimum_reply_byte_count,
        (try Capacity.derive(.{ .reply_byte_count = minimum_reply_byte_count })).reply_byte_count,
    );
    try std.testing.expectError(error.ReplyStorageUnaligned, Capacity.derive(.{
        .reply_byte_count = 5,
    }));
    if (@sizeOf(usize) > @sizeOf(u32)) {
        try std.testing.expectError(error.ReplyStorageTooLarge, Capacity.derive(.{
            .reply_byte_count = @as(usize, @intCast(protocol.maximum_reply_extra_byte_count)) + 4,
        }));
    }
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_message_count = std.math.maxInt(usize) / message_bytes + 1,
    }));
}

test "connection storage acquires all regions before readiness" {
    const capacity = try Capacity.derive(.{
        .retained_message_count = 2,
        .request_byte_count = protocol.minimum_request_byte_count,
        .reply_byte_count = 4,
    });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(error.OutOfMemory, Storage.init(failing.allocator(), capacity));

    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    try std.testing.expectError(error.OutOfMemory, Storage.init(failing.allocator(), capacity));

    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 2,
    });
    try std.testing.expectError(error.OutOfMemory, Storage.init(failing.allocator(), capacity));

    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 3,
    });
    try std.testing.expectError(error.OutOfMemory, Storage.init(failing.allocator(), capacity));

    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 4,
    });
    var storage = try Storage.init(failing.allocator(), capacity);
    defer storage.deinit();
    try std.testing.expectEqual(@as(usize, 2), storage.retained_messages.items.len);
    try std.testing.expectEqual(
        protocol.minimum_request_byte_count,
        storage.request.len,
    );
    try std.testing.expectEqual(@as(usize, 4), storage.reply.len);
    try std.testing.expectEqual(
        capacity.initialization_scratch_byte_count,
        storage.initialization_scratch.len,
    );
    try std.testing.expectEqual(@as(usize, 4), failing.allocations);
    storage.releaseInitializationScratch();
    try std.testing.expectEqual(@as(usize, 0), storage.initialization_scratch.len);
    try std.testing.expectEqual(@as(usize, 1), failing.deallocations);
}

test "retained messages preserve FIFO order without steady allocation" {
    const capacity = try Capacity.derive(.{ .retained_message_count = 2 });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        RetainedMessages.init(failing.allocator(), capacity),
    );

    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    var retained = try RetainedMessages.init(failing.allocator(), capacity);
    defer retained.deinit();

    const first: Message = @splat(1);
    const second: Message = @splat(2);
    const third: Message = @splat(3);
    try retained.append(first);
    try retained.append(second);
    try std.testing.expectError(
        error.RetainedMessageCapacityExceeded,
        retained.append(third),
    );
    try std.testing.expectEqual(first, retained.pop().?);
    try retained.append(third);
    try std.testing.expectEqual(second, retained.pop().?);
    try std.testing.expectEqual(third, retained.pop().?);
    try std.testing.expect(retained.pop() == null);
    try std.testing.expectEqual(Status{
        .retained_message_capacity_rejection_count = 1,
    }, retained.status());

    retained.rejection_count = std.math.maxInt(u64);
    try retained.append(first);
    try retained.append(second);
    try std.testing.expectError(
        error.RetainedMessageCapacityExceeded,
        retained.append(third),
    );
    try std.testing.expectEqual(Status{
        .retained_message_capacity_rejection_count = std.math.maxInt(u64),
    }, retained.status());
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
}

test "reply wait rejects before consuming a message that cannot be retained" {
    const capacity = try Capacity.derive(.{
        .retained_message_count = 1,
        .reply_byte_count = 4,
    });
    var request_storage: [protocol.minimum_request_byte_count]u8 = undefined;
    var reply_storage: [4]u8 = undefined;
    var connection: Connection = .{
        .allocator = std.testing.allocator,
        .target = undefined,
        .stream = undefined,
        .setup = undefined,
        .screen = 0,
        .retained_messages = try RetainedMessages.init(std.testing.allocator, capacity),
        .request_storage = &request_storage,
        .request_scratch = protocol.Request.init(&request_storage, request_storage.len),
        .reply_storage = &reply_storage,
    };
    defer connection.retained_messages.deinit();

    const retained: Message = @splat(7);
    try connection.retainMessage(retained);

    var blocked: Message = @splat(0);
    blocked[0] = @backingInt(protocol.EventCode.key_press);
    var reply: Message = @splat(0);
    reply[0] = @backingInt(protocol.EventCode.reply);
    connection.receive_head = blocked;
    connection.receive_head_count = protocol.message_length;

    try std.testing.expectError(
        error.RetainedMessageCapacityExceeded,
        connection.waitReply(),
    );
    try std.testing.expectEqual(protocol.message_length, connection.receive_head_count);
    try std.testing.expectEqual(retained, (try connection.nextMessage()).?);
    try std.testing.expectEqual(blocked, (try connection.nextMessage()).?);
    connection.receive_head = reply;
    connection.receive_head_count = protocol.message_length;
    const received_reply = try connection.waitReply();
    try std.testing.expectEqual(reply, received_reply.head);
    const request = connection.beginRequest();
    try protocol.sendEvent(request, 1, 0, &blocked);
    try protocol.windowRequest(request, .map_window, 1);
    try std.testing.expectError(
        error.RequestCapacityExceeded,
        protocol.windowRequest(request, .unmap_window, 1),
    );
    try std.testing.expectEqual(Status{
        .retained_message_capacity_rejection_count = 1,
        .request_capacity_rejection_count = 1,
    }, connection.storageStatus());
}

test "reply storage recovers after max plus one without steady allocation" {
    const sockets = net.socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer net.close(sockets[0]);
    defer net.close(sockets[1]);

    const capacity = try Capacity.derive(.{
        .retained_message_count = 1,
        .request_byte_count = protocol.minimum_request_byte_count,
        .reply_byte_count = 4,
    });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    var request_storage: [protocol.minimum_request_byte_count]u8 = undefined;
    var reply_storage: [4]u8 = undefined;
    var connection: Connection = .{
        .allocator = failing.allocator(),
        .target = undefined,
        .stream = net.Stream.initFd(sockets[1]),
        .setup = undefined,
        .screen = 0,
        .retained_messages = try RetainedMessages.init(failing.allocator(), capacity),
        .request_storage = &request_storage,
        .request_scratch = protocol.Request.init(&request_storage, request_storage.len),
        .reply_storage = &reply_storage,
    };
    defer connection.retained_messages.deinit();

    var oversized_head: Message = @splat(0);
    oversized_head[0] = @backingInt(protocol.EventCode.reply);
    std.mem.writeInt(u32, oversized_head[4..8], 2, .little);
    var exact_head: Message = @splat(0);
    exact_head[0] = @backingInt(protocol.EventCode.reply);
    std.mem.writeInt(u32, exact_head[4..8], 1, .little);

    const peer = net.Stream.initFd(sockets[0]);
    try peer.writeAll(&oversized_head);
    try peer.writeAll("eight888");
    try peer.writeAll(&exact_head);
    try peer.writeAll("four");

    try std.testing.expectError(error.ReplyCapacityExceeded, connection.waitReply());
    const exact = try connection.waitReply();
    try std.testing.expectEqual(exact_head, exact.head);
    try std.testing.expectEqualStrings("four", exact.extra);
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
    try std.testing.expectEqual(@as(u64, 1), connection.storageStatus().reply_capacity_rejection_count);

    connection.reply_capacity_rejection_count = std.math.maxInt(u64);
    try peer.writeAll(&oversized_head);
    try peer.writeAll("eight888");
    try std.testing.expectError(error.ReplyCapacityExceeded, connection.waitReply());
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        connection.storageStatus().reply_capacity_rejection_count,
    );
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
}

test "connection performs the setup handshake against a live display" {
    if (env.get("DISPLAY") == null) return error.SkipZigTest;

    const capacity = try Capacity.derive(.{});
    var connection = Connection.connect(std.testing.allocator, capacity) catch |err| switch (err) {
        error.ConnectionFailed, error.AuthenticationFailed => return error.SkipZigTest,
        else => return err,
    };
    defer connection.close();

    try std.testing.expect(connection.setup.root != 0);
    try std.testing.expect(connection.setup.visual != 0);
    try std.testing.expect(connection.setup.max_request_units >= 4096);
    try std.testing.expect(connection.setup.visual_depth == 24 or connection.setup.visual_depth == 32);

    const first = connection.generateId();
    const second = connection.generateId();
    try std.testing.expect(first != second);

    const protocols = try connection.internAtom("WM_PROTOCOLS");
    try std.testing.expect(protocols != 0);
    const again = try connection.internAtom("WM_PROTOCOLS");
    try std.testing.expectEqual(protocols, again);
}

test "observed barrier counts batched requests and retains overflow across wrapped refusal" {
    const sockets = net.socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer net.close(sockets[0]);
    defer net.close(sockets[1]);
    const capacity = try Capacity.derive(.{ .retained_message_count = 2, .reply_byte_count = 0 });
    var request_storage: [protocol.minimum_request_byte_count]u8 = undefined;
    var connection: Connection = .{
        .allocator = std.testing.allocator,
        .target = undefined,
        .stream = net.Stream.initFd(sockets[1]),
        .setup = undefined,
        .screen = 0,
        .sent_sequence = 65534,
        .retained_messages = try RetainedMessages.init(std.testing.allocator, capacity),
        .request_storage = &request_storage,
        .request_scratch = protocol.Request.init(&request_storage, request_storage.len),
        .reply_storage = &.{},
    };
    defer connection.retained_messages.deinit();
    const peer = net.Stream.initFd(sockets[0]);
    try std.testing.expectEqual(@as(u16, 65535), connection.nextRequestSequence());
    const request = connection.beginRequest();
    try protocol.createPixmap(request, .{ .depth = 24, .pixmap = 2, .drawable = 1, .width = 16, .height = 16 });
    try protocol.getInputFocus(request);
    try connection.sendRequest();
    try std.testing.expectEqual(@as(u16, 0), connection.sent_sequence);
    try std.testing.expectEqual(@as(u16, 1), connection.nextRequestSequence());
    var sent: [20]u8 = undefined;
    try readExact(peer, &sent);
    try std.testing.expectEqualSlices(u8, request.bytes(), &sent);

    var unrelated: Message = @splat(0);
    unrelated[1] = 11;
    unrelated[10] = 53;
    std.mem.writeInt(u16, unrelated[2..4], 65534, .little);
    var refusal = unrelated;
    std.mem.writeInt(u16, refusal[2..4], 65535, .little);
    std.mem.writeInt(u32, refusal[4..8], 0xdeadbeef, .little);
    var configure: Message = @splat(0);
    configure[0] = @backingInt(protocol.EventCode.configure_notify);
    var input_event: Message = @splat(0);
    input_event[0] = @backingInt(protocol.EventCode.key_press);
    var reply: Message = @splat(0);
    reply[0] = 1;
    for ([_]Message{ unrelated, refusal, configure, input_event, reply }) |message| try peer.writeAll(&message);

    var watched = ReplyObservation{ .reply_sequence = 0, .request_sequence = 65535, .request_opcode = 53 };
    try std.testing.expectError(error.RetainedMessageCapacityExceeded, connection.waitReplyObserved(&watched));
    try std.testing.expectEqual(@as(u8, 11), watched.failure.?.code);
    try std.testing.expectEqual(@as(u16, 65535), watched.failure.?.sequence);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), watched.failure.?.value);
    try std.testing.expectEqual(protocol.message_length, connection.receive_head_count);
    try std.testing.expectEqual(@as(u64, 1), connection.storageStatus().retained_message_capacity_rejection_count);
    try std.testing.expectEqual(unrelated, (try connection.nextMessage()).?);
    try std.testing.expectEqual(configure, (try connection.nextMessage()).?);
    try std.testing.expectEqual(input_event, (try connection.nextMessage()).?);
    const barrier = try connection.waitReplyObserved(&watched);
    try std.testing.expectEqual(reply, barrier.head);
    try std.testing.expectEqual(@as(u8, 11), watched.failure.?.code);
    try std.testing.expectEqual(@as(usize, 0), connection.retained_messages.count);
}

test "observed reply mismatch drains its payload and preserves subsequent framing" {
    const sockets = net.socketPairUnixStream() catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer net.close(sockets[0]);
    defer net.close(sockets[1]);
    const capacity = try Capacity.derive(.{ .retained_message_count = 1, .reply_byte_count = 4 });
    var request_storage: [protocol.minimum_request_byte_count]u8 = undefined;
    var reply_storage: [4]u8 = undefined;
    var connection: Connection = .{
        .allocator = std.testing.allocator,
        .target = undefined,
        .stream = net.Stream.initFd(sockets[1]),
        .setup = undefined,
        .screen = 0,
        .retained_messages = try RetainedMessages.init(std.testing.allocator, capacity),
        .request_storage = &request_storage,
        .request_scratch = protocol.Request.init(&request_storage, request_storage.len),
        .reply_storage = &reply_storage,
    };
    defer connection.retained_messages.deinit();
    const peer = net.Stream.initFd(sockets[0]);
    var reply: Message = @splat(0);
    reply[0] = 1;
    std.mem.writeInt(u16, reply[2..4], 8, .little);
    std.mem.writeInt(u32, reply[4..8], 1, .little);
    try peer.writeAll(&reply);
    try peer.writeAll("old!");
    std.mem.writeInt(u16, reply[2..4], 9, .little);
    try peer.writeAll(&reply);
    try peer.writeAll("next");
    var watched = ReplyObservation{ .reply_sequence = 9, .request_sequence = 7, .request_opcode = 53 };
    try std.testing.expectError(error.UnexpectedReply, connection.waitReplyObserved(&watched));
    const received = try connection.waitReplyObserved(&watched);
    try std.testing.expectEqualStrings("next", received.extra);
    try std.testing.expectEqual(reply, received.head);
    try std.testing.expect(watched.failure == null);
}

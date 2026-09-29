const std = @import("std");
const sys = @import("sys");
const wayland = @import("root.zig");

pub const ReceiveStatus = enum {
    data,
    pending,
    closed,
};

pub const Limits = wayland.stream.Limits;
pub const Capacity = wayland.stream.Capacity;
pub const CapacityError = wayland.stream.CapacityError;
pub const StorageError = wayland.stream.StorageError;
pub const Status = wayland.stream.Status;
pub const default_byte_count = wayland.stream.default_byte_count;
pub const default_descriptor_count = wayland.stream.default_descriptor_count;
const test_capacity = Capacity.derive(.{}) catch unreachable;

pub const Storage = struct {
    inbox: wayland.stream.Inbox,
    outbox: wayland.stream.Outbox,

    pub fn init(
        session_allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Storage {
        var inbox = try wayland.stream.Inbox.init(session_allocator, capacity);
        errdefer inbox.deinit();
        return .{
            .inbox = inbox,
            .outbox = try wayland.stream.Outbox.init(session_allocator, capacity),
        };
    }

    pub fn deinit(self: *Storage) void {
        self.inbox.deinit();
        self.outbox.deinit();
        self.* = undefined;
    }

    pub fn attach(
        self: *Storage,
        owned_descriptor: sys.fd.Descriptor,
    ) sys.fd.FlagError!Transport {
        errdefer sys.fd.close(owned_descriptor);
        try sys.fd.setCloseOnExec(owned_descriptor);
        try sys.fd.setNonBlocking(owned_descriptor);
        const transport: Transport = .{
            .descriptor = owned_descriptor,
            .inbox = self.inbox,
            .outbox = self.outbox,
        };
        self.* = undefined;
        return transport;
    }
};

pub const Transport = struct {
    descriptor: sys.fd.Descriptor,
    inbox: wayland.stream.Inbox,
    outbox: wayland.stream.Outbox,

    pub fn initOwned(
        session_allocator: std.mem.Allocator,
        descriptor: sys.fd.Descriptor,
        capacity: Capacity,
    ) (sys.fd.FlagError || std.mem.Allocator.Error)!Transport {
        var storage = Storage.init(session_allocator, capacity) catch |err| {
            sys.fd.close(descriptor);
            return err;
        };
        errdefer storage.deinit();
        return storage.attach(descriptor);
    }

    pub fn deinit(self: *Transport) void {
        self.inbox.deinit();
        self.outbox.deinit();
        sys.fd.close(self.descriptor);
        self.* = undefined;
    }

    pub fn queueOwned(
        self: *Transport,
        object_id: u32,
        opcode: u16,
        payload: []const u8,
        descriptors: []const sys.fd.Descriptor,
    ) !void {
        try self.outbox.queueOwned(object_id, opcode, payload, descriptors);
    }

    pub fn flush(self: *Transport) !wayland.stream.FlushStatus {
        return self.outbox.flush(self.descriptor);
    }

    pub fn receive(self: *Transport) !ReceiveStatus {
        const bytes = try self.inbox.prepareReceive(16 * 1024);
        var descriptors: [sys.ancillary.maximum_descriptors]sys.fd.Descriptor = undefined;
        const received = sys.ancillary.receive(self.descriptor, bytes, &descriptors) catch |err| switch (err) {
            error.WouldBlock => return .pending,
            else => return err,
        };
        if (received.byte_count == 0) {
            std.debug.assert(received.descriptor_count == 0);
            return .closed;
        }
        self.inbox.commitReceived(
            received.byte_count,
            descriptors[0..received.descriptor_count],
        ) catch |err| {
            closeAll(descriptors[0..received.descriptor_count]);
            return err;
        };
        return .data;
    }

    pub fn status(self: *const Transport) Status {
        const inbound = self.inbox.status();
        const outbound = self.outbox.status();
        return .{
            .inbound_byte_capacity_rejection_count = inbound.inbound_byte_capacity_rejection_count,
            .inbound_descriptor_capacity_rejection_count = inbound.inbound_descriptor_capacity_rejection_count,
            .outbound_byte_capacity_rejection_count = outbound.outbound_byte_capacity_rejection_count,
            .outbound_descriptor_capacity_rejection_count = outbound.outbound_descriptor_capacity_rejection_count,
        };
    }
};

fn closeAll(descriptors: []const sys.fd.Descriptor) void {
    for (descriptors) |descriptor| sys.fd.close(descriptor);
}

test "transport storage acquires all four regions before attachment" {
    const capacity = try Capacity.derive(.{
        .inbound_byte_count = 8,
        .inbound_descriptor_count = 1,
        .outbound_byte_count = 8,
        .outbound_descriptor_count = 1,
    });
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        try std.testing.expectError(
            error.OutOfMemory,
            Storage.init(failing.allocator(), capacity),
        );
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 4,
    });
    var storage = try Storage.init(failing.allocator(), capacity);
    defer storage.deinit();
    try std.testing.expectEqual(@as(usize, 4), failing.allocations);
    try std.testing.expectEqual(@as(usize, 8), storage.inbox.bytes.len);
    try std.testing.expectEqual(@as(usize, 1), storage.inbox.descriptors.len);
    try std.testing.expectEqual(@as(usize, 8), storage.outbox.bytes.len);
    try std.testing.expectEqual(@as(usize, 1), storage.outbox.descriptors.len);
}

test "owned descriptor closes when initial storage acquisition fails" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer sys.fd.close(sockets[1]);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        Transport.initOwned(failing.allocator(), sockets[0], test_capacity),
    );
    try std.testing.expect(!sys.fd.isOpen(sockets[0]));
}

test "transport preserves descriptor order over a Unix stream" {
    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    var sender = Transport.initOwned(std.testing.allocator, sockets[0], test_capacity) catch |err| {
        sys.fd.close(sockets[1]);
        return err;
    };
    defer sender.deinit();
    var receiver = try Transport.initOwned(std.testing.allocator, sockets[1], test_capacity);
    defer receiver.deinit();

    const first_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(first_pipe[0]);
    const second_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(second_pipe[0]);
    var queued = false;
    defer if (!queued) {
        sys.fd.close(first_pipe[1]);
        sys.fd.close(second_pipe[1]);
    };

    try sender.queueOwned(2, 5, &.{ 9, 8, 7, 6 }, &.{ first_pipe[1], second_pipe[1] });
    queued = true;
    try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try sender.flush());
    try std.testing.expectEqual(ReceiveStatus.data, try receiver.receive());

    const frame = (try receiver.inbox.peek()).?;
    try std.testing.expectEqual(@as(u32, 2), frame.header.object_id);
    try std.testing.expectEqual(@as(u16, 5), frame.header.opcode);
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, frame.payload);

    const received_first = receiver.inbox.takeDescriptor().?;
    defer sys.fd.close(received_first);
    const received_second = receiver.inbox.takeDescriptor().?;
    defer sys.fd.close(received_second);
    try std.testing.expect(receiver.inbox.takeDescriptor() == null);
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.write(received_first, "a"));
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.write(received_second, "b"));

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.read(first_pipe[0], &byte));
    try std.testing.expectEqual(@as(u8, 'a'), byte[0]);
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.read(second_pipe[0], &byte));
    try std.testing.expectEqual(@as(u8, 'b'), byte[0]);
    try receiver.inbox.consume();
}

test "received descriptors queue independently of fragmented bytes" {
    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer sys.fd.close(sockets[0]);
    var receiver = Transport.initOwned(std.testing.allocator, sockets[1], test_capacity) catch |err| {
        return err;
    };
    defer receiver.deinit();

    const pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(pipe[0]);
    defer sys.fd.close(pipe[1]);
    const header = try wayland.wire.Header.init(2, 1, 4);
    var message: [12]u8 = undefined;
    try header.encode(message[0..8]);
    @memcpy(message[8..], &[_]u8{ 1, 2, 3, 4 });

    try std.testing.expectEqual(@as(usize, 1), try sys.ancillary.send(sockets[0], message[0..1], &.{pipe[1]}));
    try std.testing.expectEqual(ReceiveStatus.data, try receiver.receive());
    try std.testing.expect((try receiver.inbox.peek()) == null);
    try std.testing.expectEqual(@as(usize, 1), receiver.inbox.queuedDescriptorCount());

    try std.testing.expectEqual(message.len - 1, try sys.fd.write(sockets[0], message[1..]));
    try std.testing.expectEqual(ReceiveStatus.data, try receiver.receive());
    try std.testing.expectEqual(header, (try receiver.inbox.peek()).?.header);
    const received = receiver.inbox.takeDescriptor().?;
    sys.fd.close(received);
}

test "inbound byte max plus one preserves the full retained prefix" {
    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    var sender = Transport.initOwned(std.testing.allocator, sockets[0], test_capacity) catch |err| {
        sys.fd.close(sockets[1]);
        return err;
    };
    defer sender.deinit();
    const receiver_capacity = try Capacity.derive(.{
        .inbound_byte_count = wayland.wire.header_size,
    });
    var receiver = try Transport.initOwned(
        std.testing.allocator,
        sockets[1],
        receiver_capacity,
    );
    defer receiver.deinit();

    try sender.queueOwned(2, 1, &.{ 1, 2, 3, 4 }, &.{});
    try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try sender.flush());
    try std.testing.expectEqual(ReceiveStatus.data, try receiver.receive());
    try std.testing.expectEqual(
        @as(usize, wayland.wire.header_size),
        receiver.inbox.queuedByteCount(),
    );
    var retained: [wayland.wire.header_size]u8 = undefined;
    @memcpy(&retained, receiver.inbox.bytes[0..receiver.inbox.byte_count]);
    try std.testing.expectError(error.InboundByteCapacityExceeded, receiver.receive());
    try std.testing.expectEqualSlices(
        u8,
        &retained,
        receiver.inbox.bytes[0..receiver.inbox.byte_count],
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        receiver.status().inbound_byte_capacity_rejection_count,
    );
}

test "inbound descriptor max plus one closes the rejected foreign batch" {
    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    const sender_capacity = try Capacity.derive(.{ .outbound_descriptor_count = 2 });
    var sender = Transport.initOwned(std.testing.allocator, sockets[0], sender_capacity) catch |err| {
        sys.fd.close(sockets[1]);
        return err;
    };
    defer sender.deinit();
    const receiver_capacity = try Capacity.derive(.{ .inbound_descriptor_count = 1 });
    var receiver = try Transport.initOwned(
        std.testing.allocator,
        sockets[1],
        receiver_capacity,
    );
    defer receiver.deinit();
    const first_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(first_pipe[0]);
    const second_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(second_pipe[0]);

    try sender.queueOwned(2, 1, &.{}, &.{ first_pipe[1], second_pipe[1] });
    try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try sender.flush());
    try std.testing.expectError(
        error.InboundDescriptorCapacityExceeded,
        receiver.receive(),
    );
    try std.testing.expectEqual(@as(usize, 0), receiver.inbox.queuedByteCount());
    try std.testing.expectEqual(@as(usize, 0), receiver.inbox.queuedDescriptorCount());
    try std.testing.expectEqual(
        @as(u64, 1),
        receiver.status().inbound_descriptor_capacity_rejection_count,
    );
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try sys.fd.read(first_pipe[0], &byte));
    try std.testing.expectEqual(@as(usize, 0), try sys.fd.read(second_pipe[0], &byte));
}

const std = @import("std");
const sys = @import("sys");
const wayland = @import("../root.zig");
const storage = @import("storage.zig");

const wire = wayland.wire;

pub const FlushStatus = enum {
    drained,
    pending,
};

pub const Outbox = struct {
    session_allocator: std.mem.Allocator,
    bytes: []u8,
    descriptors: []sys.fd.Descriptor,
    byte_count: usize = 0,
    descriptor_count: usize = 0,
    byte_offset: usize = 0,
    descriptor_offset: usize = 0,
    byte_capacity_rejection_count: u64 = 0,
    descriptor_capacity_rejection_count: u64 = 0,

    pub fn init(
        session_allocator: std.mem.Allocator,
        capacity: storage.Capacity,
    ) std.mem.Allocator.Error!Outbox {
        const bytes = try session_allocator.alloc(u8, capacity.outbound_byte_count);
        errdefer session_allocator.free(bytes);
        return .{
            .session_allocator = session_allocator,
            .bytes = bytes,
            .descriptors = try session_allocator.alloc(
                sys.fd.Descriptor,
                capacity.outbound_descriptor_count,
            ),
        };
    }

    pub fn deinit(self: *Outbox) void {
        self.assertValid();
        closeAll(self.descriptors[self.descriptor_offset..self.descriptor_count]);
        self.session_allocator.free(self.bytes);
        if (self.descriptors.len != 0) self.session_allocator.free(self.descriptors);
        self.* = undefined;
    }

    pub fn queueOwned(
        self: *Outbox,
        object_id: u32,
        opcode: u16,
        payload: []const u8,
        descriptors: []const sys.fd.Descriptor,
    ) (wire.Error || storage.StorageError || error{TooManyDescriptors})!void {
        if (descriptors.len > sys.ancillary.maximum_descriptors) return error.TooManyDescriptors;
        const header = try wire.Header.init(object_id, opcode, payload.len);
        var encoded: [wire.header_size]u8 = undefined;
        try header.encode(&encoded);

        self.compact();
        const message_byte_count = encoded.len + payload.len;
        var failure: ?storage.StorageError = null;
        if (message_byte_count > self.bytes.len - self.byte_count) {
            self.byte_capacity_rejection_count +|= 1;
            failure = error.OutboundByteCapacityExceeded;
        }
        if (descriptors.len > self.descriptors.len - self.descriptor_count) {
            self.descriptor_capacity_rejection_count +|= 1;
            if (failure == null) failure = error.OutboundDescriptorCapacityExceeded;
        }
        if (failure) |err| return err;
        @memcpy(self.bytes[self.byte_count..][0..encoded.len], &encoded);
        self.byte_count += encoded.len;
        @memcpy(self.bytes[self.byte_count..][0..payload.len], payload);
        self.byte_count += payload.len;
        @memcpy(
            self.descriptors[self.descriptor_count..][0..descriptors.len],
            descriptors,
        );
        self.descriptor_count += descriptors.len;
        self.assertValid();
    }

    pub fn flush(self: *Outbox, socket: sys.fd.Descriptor) !FlushStatus {
        while (self.byte_offset < self.byte_count) {
            const pending_bytes = self.bytes[self.byte_offset..self.byte_count];
            const pending_descriptors = self.descriptors[self.descriptor_offset..self.descriptor_count];
            const descriptor_count = @min(pending_descriptors.len, sys.ancillary.maximum_descriptors);
            const bytes = if (pending_descriptors.len > descriptor_count)
                pending_bytes[0..1]
            else
                pending_bytes;
            const descriptors = pending_descriptors[0..descriptor_count];
            const sent = sys.ancillary.send(socket, bytes, descriptors) catch |err| switch (err) {
                error.WouldBlock => return .pending,
                else => return err,
            };
            if (sent == 0) return error.SendFailed;
            closeAll(descriptors);
            self.descriptor_offset += descriptors.len;
            self.byte_offset += sent;
            self.assertValid();
        }

        std.debug.assert(self.descriptor_offset == self.descriptor_count);
        self.byte_count = 0;
        self.descriptor_count = 0;
        self.byte_offset = 0;
        self.descriptor_offset = 0;
        self.assertValid();
        return .drained;
    }

    pub fn pendingByteCount(self: *const Outbox) usize {
        return self.byte_count - self.byte_offset;
    }

    pub fn pendingDescriptorCount(self: *const Outbox) usize {
        return self.descriptor_count - self.descriptor_offset;
    }

    pub fn status(self: *const Outbox) storage.Status {
        return .{
            .outbound_byte_capacity_rejection_count = self.byte_capacity_rejection_count,
            .outbound_descriptor_capacity_rejection_count = self.descriptor_capacity_rejection_count,
        };
    }

    fn compact(self: *Outbox) void {
        storage.compactSlice(u8, self.bytes, &self.byte_count, &self.byte_offset);
        storage.compactSlice(
            sys.fd.Descriptor,
            self.descriptors,
            &self.descriptor_count,
            &self.descriptor_offset,
        );
    }

    fn assertValid(self: *const Outbox) void {
        std.debug.assert(self.byte_offset <= self.byte_count);
        std.debug.assert(self.byte_count <= self.bytes.len);
        std.debug.assert(self.descriptor_offset <= self.descriptor_count);
        std.debug.assert(self.descriptor_count <= self.descriptors.len);
    }
};

fn closeAll(descriptors: []const sys.fd.Descriptor) void {
    for (descriptors) |descriptor| sys.fd.close(descriptor);
}

test "outbox retains partial writes under socket backpressure" {
    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer sys.fd.close(sockets[0]);
    defer sys.fd.close(sockets[1]);
    try sys.fd.setNonBlocking(sockets[0]);

    const capacity = try storage.Capacity.derive(.{
        .outbound_byte_count = 16 * @as(usize, wire.maximum_message_size),
    });
    var outbox = try Outbox.init(std.testing.allocator, capacity);
    defer outbox.deinit();
    var payload: [wire.maximum_message_size - wire.header_size]u8 = @splat(0xa5);
    for (0..16) |index_value| {
        try outbox.queueOwned(2, @intCast(index_value), &payload, &.{});
    }
    const initial = outbox.pendingByteCount();
    try std.testing.expectEqual(FlushStatus.pending, try outbox.flush(sockets[0]));
    try std.testing.expect(outbox.pendingByteCount() > 0);
    try std.testing.expect(outbox.pendingByteCount() < initial);
}

test "outbox retains owned descriptors while the socket would block" {
    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    defer sys.fd.close(sockets[0]);
    defer sys.fd.close(sockets[1]);
    try sys.fd.setNonBlocking(sockets[0]);

    const fill: [4096]u8 = @splat(0xcc);
    while (true) {
        _ = sys.fd.write(sockets[0], &fill) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }

    const pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(pipe[0]);
    var queued = false;
    defer if (!queued) sys.fd.close(pipe[1]);
    const capacity = try storage.Capacity.derive(.{ .outbound_descriptor_count = 1 });
    var outbox = try Outbox.init(std.testing.allocator, capacity);
    defer outbox.deinit();
    try outbox.queueOwned(2, 0, &.{}, &.{pipe[1]});
    queued = true;

    try std.testing.expectEqual(FlushStatus.pending, try outbox.flush(sockets[0]));
    try std.testing.expectEqual(@as(usize, 1), outbox.pendingDescriptorCount());
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.write(pipe[1], "x"));
    var received: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.read(pipe[0], &received));
    try std.testing.expectEqual(@as(u8, 'x'), received[0]);
}

test "outbox max plus one preserves retained bytes and saturates status" {
    const capacity = try storage.Capacity.derive(.{ .outbound_byte_count = 8 });
    var outbox = try Outbox.init(std.testing.allocator, capacity);
    defer outbox.deinit();

    try outbox.queueOwned(2, 0, &.{}, &.{});
    try std.testing.expectError(
        error.OutboundByteCapacityExceeded,
        outbox.queueOwned(3, 1, &.{}, &.{}),
    );
    try std.testing.expectEqual(@as(usize, 8), outbox.pendingByteCount());
    try std.testing.expectEqual(@as(u64, 1), outbox.status().outbound_byte_capacity_rejection_count);

    outbox.byte_capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(
        error.OutboundByteCapacityExceeded,
        outbox.queueOwned(3, 1, &.{}, &.{}),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        outbox.status().outbound_byte_capacity_rejection_count,
    );
}

test "outbox max plus one leaves rejected descriptor with caller" {
    const first_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(first_pipe[0]);
    const second_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(second_pipe[0]);
    defer sys.fd.close(second_pipe[1]);

    const capacity = try storage.Capacity.derive(.{
        .outbound_byte_count = 2 * wire.header_size,
        .outbound_descriptor_count = 1,
    });
    var outbox = try Outbox.init(std.testing.allocator, capacity);
    defer outbox.deinit();
    try outbox.queueOwned(2, 0, &.{}, &.{first_pipe[1]});
    try std.testing.expectError(
        error.OutboundDescriptorCapacityExceeded,
        outbox.queueOwned(3, 1, &.{}, &.{second_pipe[1]}),
    );
    try std.testing.expectEqual(@as(usize, 8), outbox.pendingByteCount());
    try std.testing.expectEqual(@as(usize, 1), outbox.pendingDescriptorCount());
    try std.testing.expectEqual(
        @as(u64, 1),
        outbox.status().outbound_descriptor_capacity_rejection_count,
    );
}

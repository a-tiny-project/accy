const std = @import("std");
const sys = @import("sys");
const wayland = @import("../root.zig");
const storage = @import("storage.zig");

const wire = wayland.wire;

pub const Frame = struct {
    header: wire.Header,
    bytes: []const u8,
    payload: []const u8,
};

pub const Inbox = struct {
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
    ) std.mem.Allocator.Error!Inbox {
        const bytes = try session_allocator.alloc(u8, capacity.inbound_byte_count);
        errdefer session_allocator.free(bytes);
        return .{
            .session_allocator = session_allocator,
            .bytes = bytes,
            .descriptors = try session_allocator.alloc(
                sys.fd.Descriptor,
                capacity.inbound_descriptor_count,
            ),
        };
    }

    pub fn deinit(self: *Inbox) void {
        self.assertValid();
        closeAll(self.descriptors[self.descriptor_offset..self.descriptor_count]);
        self.session_allocator.free(self.bytes);
        if (self.descriptors.len != 0) self.session_allocator.free(self.descriptors);
        self.* = undefined;
    }

    pub fn appendOwned(
        self: *Inbox,
        bytes: []const u8,
        descriptors: []const sys.fd.Descriptor,
    ) storage.StorageError!void {
        self.compact();
        var failure: ?storage.StorageError = null;
        if (bytes.len > self.bytes.len - self.byte_count) {
            self.byte_capacity_rejection_count +|= 1;
            failure = error.InboundByteCapacityExceeded;
        }
        if (descriptors.len > self.descriptors.len - self.descriptor_count) {
            self.descriptor_capacity_rejection_count +|= 1;
            if (failure == null) failure = error.InboundDescriptorCapacityExceeded;
        }
        if (failure) |err| return err;
        @memcpy(self.bytes[self.byte_count..][0..bytes.len], bytes);
        @memcpy(
            self.descriptors[self.descriptor_count..][0..descriptors.len],
            descriptors,
        );
        self.byte_count += bytes.len;
        self.descriptor_count += descriptors.len;
        self.assertValid();
    }

    pub fn prepareReceive(
        self: *Inbox,
        maximum_byte_count: usize,
    ) storage.StorageError![]u8 {
        std.debug.assert(maximum_byte_count > 0);
        self.compact();
        const available = self.bytes.len - self.byte_count;
        if (available == 0) {
            self.byte_capacity_rejection_count +|= 1;
            return error.InboundByteCapacityExceeded;
        }
        return self.bytes[self.byte_count..][0..@min(available, maximum_byte_count)];
    }

    pub fn commitReceived(
        self: *Inbox,
        byte_count: usize,
        descriptors: []const sys.fd.Descriptor,
    ) storage.StorageError!void {
        std.debug.assert(byte_count > 0);
        std.debug.assert(byte_count <= self.bytes.len - self.byte_count);
        if (descriptors.len > self.descriptors.len - self.descriptor_count) {
            self.descriptor_capacity_rejection_count +|= 1;
            return error.InboundDescriptorCapacityExceeded;
        }
        @memcpy(
            self.descriptors[self.descriptor_count..][0..descriptors.len],
            descriptors,
        );
        self.byte_count += byte_count;
        self.descriptor_count += descriptors.len;
        self.assertValid();
    }

    pub fn peek(self: *const Inbox) wire.Error!?Frame {
        self.assertValid();
        const available = self.bytes[self.byte_offset..self.byte_count];
        if (available.len < wire.header_size) return null;
        const header = try wire.decode(available[0..wire.header_size]);
        if (available.len < header.size) return null;
        return .{
            .header = header,
            .bytes = available[0..header.size],
            .payload = available[wire.header_size..header.size],
        };
    }

    pub fn consume(self: *Inbox) (wire.Error || error{IncompleteMessage})!void {
        self.assertValid();
        const frame = (try self.peek()) orelse return error.IncompleteMessage;
        self.byte_offset += frame.header.size;
        if (self.byte_offset == self.byte_count) {
            self.byte_count = 0;
            self.byte_offset = 0;
        }
        self.assertValid();
    }

    pub fn takeDescriptor(self: *Inbox) ?sys.fd.Descriptor {
        self.assertValid();
        if (self.descriptor_offset == self.descriptor_count) return null;
        const descriptor = self.descriptors[self.descriptor_offset];
        self.descriptor_offset += 1;
        if (self.descriptor_offset == self.descriptor_count) {
            self.descriptor_count = 0;
            self.descriptor_offset = 0;
        }
        self.assertValid();
        return descriptor;
    }

    pub fn peekDescriptors(self: *const Inbox, count: usize) ?[]const sys.fd.Descriptor {
        if (count > self.queuedDescriptorCount()) return null;
        return self.descriptors[self.descriptor_offset..self.descriptor_count][0..count];
    }

    pub fn queuedByteCount(self: *const Inbox) usize {
        return self.byte_count - self.byte_offset;
    }

    pub fn queuedDescriptorCount(self: *const Inbox) usize {
        return self.descriptor_count - self.descriptor_offset;
    }

    pub fn status(self: *const Inbox) storage.Status {
        return .{
            .inbound_byte_capacity_rejection_count = self.byte_capacity_rejection_count,
            .inbound_descriptor_capacity_rejection_count = self.descriptor_capacity_rejection_count,
        };
    }

    fn compact(self: *Inbox) void {
        storage.compactSlice(u8, self.bytes, &self.byte_count, &self.byte_offset);
        storage.compactSlice(
            sys.fd.Descriptor,
            self.descriptors,
            &self.descriptor_count,
            &self.descriptor_offset,
        );
    }

    fn assertValid(self: *const Inbox) void {
        std.debug.assert(self.byte_offset <= self.byte_count);
        std.debug.assert(self.byte_count <= self.bytes.len);
        std.debug.assert(self.descriptor_offset <= self.descriptor_count);
        std.debug.assert(self.descriptor_count <= self.descriptors.len);
    }
};

fn closeAll(descriptors: []const sys.fd.Descriptor) void {
    for (descriptors) |descriptor| sys.fd.close(descriptor);
}

test "inbox preserves fragmented and coalesced message boundaries" {
    const first_header = try wire.Header.init(2, 7, 4);
    const second_header = try wire.Header.init(3, 9, 0);
    var first: [12]u8 = undefined;
    var second: [8]u8 = undefined;
    try first_header.encode(first[0..8]);
    @memcpy(first[8..], &[_]u8{ 1, 2, 3, 4 });
    try second_header.encode(&second);

    const capacity = try storage.Capacity.derive(.{ .inbound_byte_count = 20 });
    var inbox = try Inbox.init(std.testing.allocator, capacity);
    defer inbox.deinit();
    try inbox.appendOwned(first[0..3], &.{});
    try std.testing.expect((try inbox.peek()) == null);
    try inbox.appendOwned(first[3..], &.{});
    try inbox.appendOwned(second[0..2], &.{});
    const first_frame = (try inbox.peek()).?;
    try std.testing.expectEqual(first_header, first_frame.header);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, first_frame.payload);
    try inbox.consume();
    try std.testing.expect((try inbox.peek()) == null);
    try inbox.appendOwned(second[2..], &.{});
    try std.testing.expectEqual(second_header, (try inbox.peek()).?.header);
    try inbox.consume();
    try std.testing.expectEqual(@as(usize, 0), inbox.queuedByteCount());
}

test "descriptor lookahead does not transfer ownership" {
    const pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(pipe[0]);

    const capacity = try storage.Capacity.derive(.{ .inbound_descriptor_count = 1 });
    var inbox = try Inbox.init(std.testing.allocator, capacity);
    defer inbox.deinit();
    try inbox.appendOwned(&.{}, &.{pipe[1]});
    try std.testing.expect(inbox.peekDescriptors(2) == null);
    try std.testing.expectEqualSlices(sys.fd.Descriptor, &.{pipe[1]}, inbox.peekDescriptors(1).?);
    try std.testing.expectEqual(pipe[1], inbox.takeDescriptor().?);
    sys.fd.close(pipe[1]);
}

test "inbox max plus one preserves retained bytes and saturates status" {
    const capacity = try storage.Capacity.derive(.{ .inbound_byte_count = 8 });
    var inbox = try Inbox.init(std.testing.allocator, capacity);
    defer inbox.deinit();

    try inbox.appendOwned(&@as([8]u8, @splat(1)), &.{});
    try std.testing.expectError(
        error.InboundByteCapacityExceeded,
        inbox.appendOwned(&.{2}, &.{}),
    );
    try std.testing.expectEqual(@as(usize, 8), inbox.queuedByteCount());
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(1)), inbox.bytes[0..inbox.byte_count]);
    try std.testing.expectEqual(@as(u64, 1), inbox.status().inbound_byte_capacity_rejection_count);

    inbox.byte_capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(
        error.InboundByteCapacityExceeded,
        inbox.prepareReceive(1),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        inbox.status().inbound_byte_capacity_rejection_count,
    );
}

test "inbox max plus one preserves retained descriptor ownership" {
    const first_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(first_pipe[0]);
    const second_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(second_pipe[0]);
    defer sys.fd.close(second_pipe[1]);

    const capacity = try storage.Capacity.derive(.{ .inbound_descriptor_count = 1 });
    var inbox = try Inbox.init(std.testing.allocator, capacity);
    defer inbox.deinit();
    try inbox.appendOwned(&.{}, &.{first_pipe[1]});
    try std.testing.expectError(
        error.InboundDescriptorCapacityExceeded,
        inbox.appendOwned(&.{}, &.{second_pipe[1]}),
    );
    try std.testing.expectEqual(@as(usize, 1), inbox.queuedDescriptorCount());
    try std.testing.expectEqual(first_pipe[1], inbox.takeDescriptor().?);
    sys.fd.close(first_pipe[1]);
    try std.testing.expectEqual(
        @as(u64, 1),
        inbox.status().inbound_descriptor_capacity_rejection_count,
    );
}

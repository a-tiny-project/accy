const std = @import("std");
const wayland = @import("root.zig");

const Transport = wayland.Transport;
const TransportCapacity = wayland.TransportCapacity;
const stream = wayland.stream;
const transport = wayland.transport;
const wire = wayland.wire;

test "Wayland transport package namespace is complete" {
    std.testing.refAllDecls(wayland);
    _ = @import("protocol/test.zig");
    _ = @import("runtime/test.zig");
    _ = @import("stream/test.zig");
}

test "interleaved requests preserve descriptor order across ancillary batches" {
    const sys = @import("sys");
    const capacity = try TransportCapacity.derive(.{
        .inbound_descriptor_count = sys.ancillary.maximum_descriptors + 1,
        .outbound_descriptor_count = sys.ancillary.maximum_descriptors + 1,
    });

    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
        error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    var sender = Transport.initOwned(std.testing.allocator, sockets[0], capacity) catch |err| {
        sys.fd.close(sockets[1]);
        return err;
    };
    defer sender.deinit();
    var receiver = try Transport.initOwned(std.testing.allocator, sockets[1], capacity);
    defer receiver.deinit();

    const first_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(first_pipe[0]);
    defer sys.fd.close(first_pipe[1]);
    const last_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(last_pipe[0]);
    defer sys.fd.close(last_pipe[1]);

    var first_descriptors: [sys.ancillary.maximum_descriptors]sys.fd.Descriptor = undefined;
    var first_descriptor_count: usize = 0;
    var first_queued = false;
    defer if (!first_queued) {
        for (first_descriptors[0..first_descriptor_count]) |descriptor| sys.fd.close(descriptor);
    };
    while (first_descriptor_count < first_descriptors.len) : (first_descriptor_count += 1) {
        first_descriptors[first_descriptor_count] = try sys.fd.duplicate(first_pipe[1]);
    }
    const last_descriptor = try sys.fd.duplicate(last_pipe[1]);
    var last_queued = false;
    defer if (!last_queued) sys.fd.close(last_descriptor);

    try sender.queueOwned(2, 10, &.{}, &first_descriptors);
    first_queued = true;
    try sender.queueOwned(3, 11, &.{}, &.{});
    try sender.queueOwned(4, 12, &.{}, &.{last_descriptor});
    last_queued = true;
    try std.testing.expectEqual(stream.FlushStatus.drained, try sender.flush());

    try std.testing.expectEqual(transport.ReceiveStatus.data, try receiver.receive());
    try std.testing.expectEqual(@as(usize, 1), receiver.inbox.queuedByteCount());
    try std.testing.expectEqual(first_descriptors.len, receiver.inbox.queuedDescriptorCount());
    try std.testing.expect((try receiver.inbox.peek()) == null);
    try std.testing.expectEqual(transport.ReceiveStatus.data, try receiver.receive());
    try std.testing.expectEqual(@as(usize, 3 * wire.header_size), receiver.inbox.queuedByteCount());
    try std.testing.expectEqual(first_descriptors.len + 1, receiver.inbox.queuedDescriptorCount());

    var received_descriptors: [first_descriptors.len + 1]sys.fd.Descriptor = undefined;
    var received_descriptor_count: usize = 0;
    defer {
        for (received_descriptors[0..received_descriptor_count]) |descriptor| sys.fd.close(descriptor);
    }

    try std.testing.expectEqual(@as(u32, 2), (try receiver.inbox.peek()).?.header.object_id);
    for (received_descriptors[0..first_descriptors.len]) |*descriptor| {
        descriptor.* = receiver.inbox.takeDescriptor().?;
        received_descriptor_count += 1;
    }
    try receiver.inbox.consume();
    try std.testing.expectEqual(@as(u32, 3), (try receiver.inbox.peek()).?.header.object_id);
    try receiver.inbox.consume();
    try std.testing.expectEqual(@as(u32, 4), (try receiver.inbox.peek()).?.header.object_id);
    received_descriptors[first_descriptors.len] = receiver.inbox.takeDescriptor().?;
    received_descriptor_count += 1;
    try receiver.inbox.consume();
    try std.testing.expect(receiver.inbox.takeDescriptor() == null);

    for (received_descriptors[0..first_descriptors.len]) |descriptor| {
        try std.testing.expectEqual(@as(usize, 1), try sys.fd.write(descriptor, "a"));
    }
    try std.testing.expectEqual(
        @as(usize, 1),
        try sys.fd.write(received_descriptors[first_descriptors.len], "b"),
    );

    var first_bytes: [first_descriptors.len]u8 = undefined;
    var first_byte_count: usize = 0;
    while (first_byte_count < first_bytes.len) {
        first_byte_count += try sys.fd.read(first_pipe[0], first_bytes[first_byte_count..]);
    }
    for (first_bytes) |byte| try std.testing.expectEqual(@as(u8, 'a'), byte);
    var last_byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.read(last_pipe[0], &last_byte));
    try std.testing.expectEqual(@as(u8, 'b'), last_byte[0]);
}

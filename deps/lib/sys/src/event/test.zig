const std = @import("std");
const subject = @import("root.zig");
const sys = @import("../root.zig");

const net = sys.net;

const CallbackAction = subject.CallbackAction;
const Datagram = subject.Datagram;
const ReadBuffer = subject.ReadBuffer;
const RecvError = subject.RecvError;
const SendError = subject.SendError;
const WriteBuffer = subject.WriteBuffer;
const Completion = subject.Completion;
const Loop = subject.Loop;
const UDP = subject.UDP;

const capture_count_max: usize = 2;
const capture_bytes_max: usize = 64;

const UdpPair = struct {
    sender: UDP,
    receiver: UDP,
    sender_address: net.IpAddress,
    receiver_address: net.IpAddress,

    fn init(address: net.IpAddress) !UdpPair {
        const sender = try UDP.bind(address);
        errdefer sender.close();
        const receiver = try UDP.bind(address);
        errdefer receiver.close();
        const sender_name = try net.socketAddressValue(sender.fd);
        const receiver_name = try net.socketAddressValue(receiver.fd);
        return .{
            .sender = sender,
            .receiver = receiver,
            .sender_address = sender_name.ipAddress() orelse return error.MissingIpAddress,
            .receiver_address = receiver_name.ipAddress() orelse return error.MissingIpAddress,
        };
    }

    fn close(self: UdpPair) void {
        self.sender.close();
        self.receiver.close();
    }
};

const ReceiveCapture = struct {
    expected_pointer: ?[*]u8,
    expected_length: usize,
    target: u8 = 1,
    hits: u8 = 0,
    same_buffer: bool = true,
    overflow: bool = false,
    datagrams: [capture_count_max]?Datagram = @splat(null),
    errors: [capture_count_max]?RecvError = @splat(null),
    payloads: [capture_count_max][capture_bytes_max]u8 = undefined,
    payload_lengths: [capture_count_max]usize = @splat(0),
};

const SendCapture = struct {
    expected: []const u8,
    expected_pointer: ?[*]const u8,
    hits: u8 = 0,
    same_buffer: bool = true,
    bytes: ?usize = null,
    err: ?SendError = null,
};

fn receiveCapture(buffer: ReadBuffer, target: u8) ReceiveCapture {
    return switch (buffer) {
        .slice => |slice| .{
            .expected_pointer = slice.ptr,
            .expected_length = slice.len,
            .target = target,
        },
        .array => |array| .{
            .expected_pointer = null,
            .expected_length = array.len,
            .target = target,
        },
    };
}

fn sendCapture(buffer: WriteBuffer, expected: []const u8) SendCapture {
    return switch (buffer) {
        .slice => |slice| .{ .expected = expected, .expected_pointer = slice.ptr },
        .array => .{ .expected = expected, .expected_pointer = null },
    };
}

fn captureReceivedBytes(
    capture: *ReceiveCapture,
    index: usize,
    buffer: ReadBuffer,
    bytes: usize,
) void {
    var source: []const u8 = undefined;
    switch (buffer) {
        .slice => |slice| {
            source = slice;
            capture.same_buffer = capture.same_buffer and
                capture.expected_pointer == slice.ptr and
                capture.expected_length == slice.len;
        },
        .array => |array| {
            source = &array;
            capture.same_buffer = capture.same_buffer and
                capture.expected_pointer == null and
                capture.expected_length == array.len;
        },
    }
    if (bytes > capture.payloads[index].len) {
        capture.overflow = true;
        return;
    }
    @memcpy(capture.payloads[index][0..bytes], source[0..bytes]);
    capture.payload_lengths[index] = bytes;
}

fn receiveCallback(
    state: ?*ReceiveCapture,
    _: *Loop,
    _: *Completion,
    _: UDP,
    buffer: ReadBuffer,
    result: RecvError!Datagram,
) CallbackAction {
    const capture = state.?;
    if (capture.hits >= capture.datagrams.len) {
        capture.overflow = true;
        return .disarm;
    }
    const index = capture.hits;
    capture.hits += 1;
    if (result) |datagram| {
        capture.datagrams[index] = datagram;
        captureReceivedBytes(capture, index, buffer, datagram.bytes);
    } else |err| {
        capture.errors[index] = err;
    }
    return if (capture.hits < capture.target) .rearm else .disarm;
}

fn sendCallback(
    state: ?*SendCapture,
    _: *Loop,
    _: *Completion,
    _: UDP,
    buffer: WriteBuffer,
    result: SendError!usize,
) CallbackAction {
    const capture = state.?;
    capture.hits += 1;
    const bytes = switch (buffer) {
        .slice => |slice| blk: {
            capture.same_buffer = capture.expected_pointer == slice.ptr;
            break :blk slice;
        },
        .array => |array| array.array[0..array.len],
    };
    capture.same_buffer = capture.same_buffer and std.mem.eql(u8, capture.expected, bytes);
    if (result) |sent| capture.bytes = sent else |err| capture.err = err;
    return .disarm;
}

fn runRoundTrip(
    pair: *const UdpPair,
    read_buffer: ReadBuffer,
    write_buffer: WriteBuffer,
    expected: []const u8,
) !void {
    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 2 });
    defer loop.deinit();
    var completions: [2]Completion = @splat(.{});
    var receive = receiveCapture(read_buffer, 1);
    var send = sendCapture(write_buffer, expected);
    pair.receiver.recvFrom(
        &loop,
        &completions[0],
        read_buffer,
        ReceiveCapture,
        &receive,
        receiveCallback,
    );
    pair.sender.sendTo(
        &loop,
        &completions[1],
        write_buffer,
        pair.receiver_address,
        SendCapture,
        &send,
        sendCallback,
    );
    try loop.run(.until_done);

    try std.testing.expectEqual(@as(u8, 1), receive.hits);
    try std.testing.expectEqual(@as(u8, 1), send.hits);
    try std.testing.expect(receive.same_buffer);
    try std.testing.expect(send.same_buffer);
    try std.testing.expectEqual(@as(?RecvError, null), receive.errors[0]);
    try std.testing.expectEqual(@as(?SendError, null), send.err);
    try std.testing.expectEqual(@as(?usize, expected.len), send.bytes);
    const datagram = receive.datagrams[0] orelse return error.MissingDatagram;
    try std.testing.expect(net.ipAddressEql(pair.sender_address, datagram.address));
    try std.testing.expectEqual(expected.len, datagram.bytes);
    try std.testing.expect(!datagram.truncated);
    try std.testing.expectEqualSlices(u8, expected, receive.payloads[0][0..datagram.bytes]);
}

test "event UDP IPv4 loopback round trip with inline buffers" {
    var pair = try UdpPair.init(.{ .ip4 = net.ip4Address(.{ 127, 0, 0, 1 }, 0) });
    defer pair.close();
    const payload = "inline datagram";
    var write_array: [32]u8 = undefined;
    @memcpy(write_array[0..payload.len], payload);
    try runRoundTrip(
        &pair,
        .{ .array = undefined },
        .{ .array = .{ .array = write_array, .len = payload.len } },
        payload,
    );
}

test "event UDP IPv4 loopback round trip with slice buffers" {
    var pair = try UdpPair.init(.{ .ip4 = net.ip4Address(.{ 127, 0, 0, 1 }, 0) });
    defer pair.close();
    const payload = "slice datagram";
    var read_buffer: [32]u8 = undefined;
    try runRoundTrip(
        &pair,
        .{ .slice = &read_buffer },
        .{ .slice = payload },
        payload,
    );
}

test "event UDP IPv6 ::1 round trip skips when the host lacks IPv6 loopback" {
    const loopback = net.ip6Address(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0);
    var pair = UdpPair.init(.{ .ip6 = loopback }) catch |err| switch (err) {
        error.UnsupportedPlatform,
        error.AddressFamilyUnsupported,
        error.ProtocolUnsupportedBySystem,
        error.ProtocolUnsupportedByAddressFamily,
        error.BindFailed,
        => return error.SkipZigTest,
        else => return err,
    };
    defer pair.close();
    const payload = "ipv6 datagram";
    var read_buffer: [32]u8 = undefined;
    try runRoundTrip(
        &pair,
        .{ .slice = &read_buffer },
        .{ .slice = payload },
        payload,
    );
}

test "event UDP reports a truncated datagram and copied byte count" {
    var pair = try UdpPair.init(.{ .ip4 = net.ip4Address(.{ 127, 0, 0, 1 }, 0) });
    defer pair.close();
    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 2 });
    defer loop.deinit();
    var completions: [2]Completion = @splat(.{});
    var read_buffer: [16]u8 = undefined;
    var payload: [64]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast(index);
    const read_value: ReadBuffer = .{ .slice = &read_buffer };
    const write_value: WriteBuffer = .{ .slice = &payload };
    var receive = receiveCapture(read_value, 1);
    var send = sendCapture(write_value, &payload);
    pair.receiver.recvFrom(
        &loop,
        &completions[0],
        read_value,
        ReceiveCapture,
        &receive,
        receiveCallback,
    );
    pair.sender.sendTo(
        &loop,
        &completions[1],
        write_value,
        pair.receiver_address,
        SendCapture,
        &send,
        sendCallback,
    );
    try loop.run(.until_done);

    const datagram = receive.datagrams[0] orelse return error.MissingDatagram;
    try std.testing.expect(datagram.truncated);
    try std.testing.expectEqual(read_buffer.len, datagram.bytes);
    try std.testing.expectEqualSlices(u8, payload[0..read_buffer.len], &read_buffer);
    try std.testing.expectEqual(@as(?usize, payload.len), send.bytes);
}

test "event UDP disarm preserves the receive buffer and suppresses its callback" {
    var pair = try UdpPair.init(.{ .ip4 = net.ip4Address(.{ 127, 0, 0, 1 }, 0) });
    defer pair.close();
    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 2 });
    defer loop.deinit();
    var completions: [2]Completion = @splat(.{});
    const initial: [16]u8 = @splat(0xa5);
    var read_buffer = initial;
    const read_value: ReadBuffer = .{ .slice = &read_buffer };
    var receive = receiveCapture(read_value, 1);
    pair.receiver.recvFrom(
        &loop,
        &completions[0],
        read_value,
        ReceiveCapture,
        &receive,
        receiveCallback,
    );
    try std.testing.expect(completions[0].active);
    loop.disarm(&completions[0]);
    try std.testing.expect(!completions[0].active);

    const payload = "after disarm";
    const write_value: WriteBuffer = .{ .slice = payload };
    var send = sendCapture(write_value, payload);
    pair.sender.sendTo(
        &loop,
        &completions[1],
        write_value,
        pair.receiver_address,
        SendCapture,
        &send,
        sendCallback,
    );
    try loop.run(.until_done);
    try std.testing.expectEqual(@as(u8, 0), receive.hits);
    try std.testing.expectEqual(initial, read_buffer);
    try std.testing.expectEqual(@as(u8, 1), send.hits);
}

test "event UDP rearm receives two datagrams through one completion" {
    var pair = try UdpPair.init(.{ .ip4 = net.ip4Address(.{ 127, 0, 0, 1 }, 0) });
    defer pair.close();
    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 3 });
    defer loop.deinit();
    var completions: [3]Completion = @splat(.{});
    var read_buffer: [32]u8 = undefined;
    const read_value: ReadBuffer = .{ .slice = &read_buffer };
    var receive = receiveCapture(read_value, 2);
    pair.receiver.recvFrom(
        &loop,
        &completions[0],
        read_value,
        ReceiveCapture,
        &receive,
        receiveCallback,
    );

    const payloads = [_][]const u8{ "first", "second" };
    var sends: [payloads.len]SendCapture = undefined;
    for (payloads, 0..) |payload, index| {
        const write_value: WriteBuffer = .{ .slice = payload };
        sends[index] = sendCapture(write_value, payload);
        pair.sender.sendTo(
            &loop,
            &completions[index + 1],
            write_value,
            pair.receiver_address,
            SendCapture,
            &sends[index],
            sendCallback,
        );
    }
    try loop.run(.until_done);

    try std.testing.expectEqual(@as(u8, payloads.len), receive.hits);
    try std.testing.expect(receive.same_buffer);
    for (payloads, 0..) |payload, index| {
        const datagram = receive.datagrams[index] orelse return error.MissingDatagram;
        try std.testing.expect(net.ipAddressEql(pair.sender_address, datagram.address));
        try std.testing.expectEqualSlices(
            u8,
            payload,
            receive.payloads[index][0..receive.payload_lengths[index]],
        );
        try std.testing.expectEqual(@as(u8, 1), sends[index].hits);
    }
}

test "event UDP surfaces EMSGSIZE for an oversized datagram" {
    var pair = try UdpPair.init(.{ .ip4 = net.ip4Address(.{ 127, 0, 0, 1 }, 0) });
    defer pair.close();
    var loop = try Loop.init(.{ .allocator = std.testing.allocator, .entries = 1 });
    defer loop.deinit();
    var completion: Completion = .{};
    var payload: [std.math.maxInt(u16) + 1]u8 = @splat(0xa5);
    const write_value: WriteBuffer = .{ .slice = &payload };
    var send = sendCapture(write_value, &payload);
    pair.sender.sendTo(
        &loop,
        &completion,
        write_value,
        pair.receiver_address,
        SendCapture,
        &send,
        sendCallback,
    );
    try loop.run(.until_done);
    try std.testing.expectEqual(@as(u8, 1), send.hits);
    try std.testing.expectEqual(@as(?SendError, error.MessageTooLarge), send.err);
    try std.testing.expectEqual(@as(?usize, null), send.bytes);
    try std.testing.expect(send.same_buffer);
}

test {
    _ = @import("poll.zig");
    std.testing.refAllDecls(subject);
}

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");

const linux = std.os.linux;
const posix = std.posix;

pub const required_capabilities = capabilities.noLibc(&.{ .descriptors, .networking });
pub const Descriptor = posix.fd_t;
pub const maximum_descriptors = 253;

pub const SendError = error{
    UnsupportedPlatform,
    EmptyMessage,
    TooManyDescriptors,
    WouldBlock,
    BrokenPipe,
    ConnectionResetByPeer,
    InvalidDescriptor,
    MessageTooLarge,
    SendFailed,
};

pub const ReceiveError = error{
    UnsupportedPlatform,
    EmptyBuffer,
    WouldBlock,
    ConnectionResetByPeer,
    DescriptorTruncated,
    MalformedControl,
    ReceiveFailed,
};

pub const Received = struct {
    byte_count: usize,
    descriptor_count: usize,
};

pub fn send(
    socket: Descriptor,
    bytes: []const u8,
    descriptors: []const Descriptor,
) SendError!usize {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (bytes.len == 0) return error.EmptyMessage;
    if (descriptors.len > maximum_descriptors) return error.TooManyDescriptors;

    var control: [controlSpace(maximum_descriptors)]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    const control_len = encodeDescriptors(&control, descriptors);
    var iovec: posix.iovec_const = .{ .base = bytes.ptr, .len = bytes.len };
    const message: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = (&iovec)[0..1],
        .iovlen = 1,
        .control = if (control_len == 0) null else &control,
        .controllen = control_len,
        .flags = 0,
    };

    while (true) {
        const result = linux.sendmsg(socket, &message, linux.MSG.NOSIGNAL);
        switch (linux.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BADF => return error.InvalidDescriptor,
            .MSGSIZE => return error.MessageTooLarge,
            else => return error.SendFailed,
        }
    }
}

pub fn receive(
    socket: Descriptor,
    bytes: []u8,
    descriptors: *[maximum_descriptors]Descriptor,
) ReceiveError!Received {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (bytes.len == 0) return error.EmptyBuffer;

    var control: [controlSpace(maximum_descriptors)]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    var iovec: posix.iovec = .{ .base = bytes.ptr, .len = bytes.len };
    var message: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = (&iovec)[0..1],
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };

    while (true) {
        const result = linux.recvmsg(socket, &message, linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(result)) {
            .SUCCESS => {
                var descriptor_count: usize = 0;
                parseDescriptors(control[0..message.controllen], descriptors, &descriptor_count) catch |err| {
                    closeAll(descriptors[0..descriptor_count]);
                    return err;
                };
                if (message.flags & linux.MSG.CTRUNC != 0) {
                    closeAll(descriptors[0..descriptor_count]);
                    return error.DescriptorTruncated;
                }
                return .{
                    .byte_count = @intCast(result),
                    .descriptor_count = descriptor_count,
                };
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => return error.ReceiveFailed,
        }
    }
}

fn encodeDescriptors(
    control: *[controlSpace(maximum_descriptors)]u8,
    descriptors: []const Descriptor,
) usize {
    if (descriptors.len == 0) return 0;

    const header: *linux.cmsghdr = @ptrCast(@alignCast(control));
    header.* = .{
        .len = controlLength(descriptors.len),
        .level = linux.SOL.SOCKET,
        .type = linux.SCM.RIGHTS,
    };
    const bytes = std.mem.sliceAsBytes(descriptors);
    @memcpy(control[controlDataOffset()..][0..bytes.len], bytes);
    return controlSpace(descriptors.len);
}

fn parseDescriptors(
    control: []align(@alignOf(linux.cmsghdr)) const u8,
    descriptors: *[maximum_descriptors]Descriptor,
    descriptor_count: *usize,
) ReceiveError!void {
    var offset: usize = 0;
    while (offset + @sizeOf(linux.cmsghdr) <= control.len) {
        const header: *const linux.cmsghdr = @ptrCast(@alignCast(control.ptr + offset));
        if (header.len < controlDataOffset() or header.len > control.len - offset) {
            return error.MalformedControl;
        }

        if (header.level == linux.SOL.SOCKET and header.type == linux.SCM.RIGHTS) {
            const data_len = header.len - controlDataOffset();
            if (data_len % @sizeOf(Descriptor) != 0) return error.MalformedControl;
            const count = data_len / @sizeOf(Descriptor);
            if (descriptor_count.* + count > descriptors.len) return error.DescriptorTruncated;
            const source = control[offset + controlDataOffset() ..][0..data_len];
            const destination = descriptors[descriptor_count.*..][0..count];
            @memcpy(std.mem.sliceAsBytes(destination), source);
            descriptor_count.* += count;
        }

        const next = offset + controlAlign(header.len);
        if (next <= offset or next > control.len) return error.MalformedControl;
        offset = next;
    }
}

fn closeAll(descriptors: []const Descriptor) void {
    for (descriptors) |descriptor| _ = linux.close(descriptor);
}

fn controlAlign(size: usize) usize {
    const alignment = @sizeOf(usize);
    const mask: usize = alignment - 1;
    return (size + mask) & ~mask;
}

fn controlDataOffset() usize {
    return controlAlign(@sizeOf(linux.cmsghdr));
}

fn controlLength(descriptor_count: usize) usize {
    return controlDataOffset() + descriptor_count * @sizeOf(Descriptor);
}

fn controlSpace(descriptor_count: usize) usize {
    return controlDataOffset() + controlAlign(descriptor_count * @sizeOf(Descriptor));
}

test "ancillary descriptor control sizing follows native alignment" {
    try std.testing.expect(controlLength(1) <= controlSpace(1));
    try std.testing.expectEqual(@as(usize, 0), controlSpace(0) % @sizeOf(usize));
    try std.testing.expectEqual(@as(usize, 0), controlSpace(maximum_descriptors) % @sizeOf(usize));
}

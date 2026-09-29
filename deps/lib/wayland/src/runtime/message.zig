const std = @import("std");
const sys = @import("sys");
const wayland = @import("../root.zig");

pub const RoutedView = struct {
    object_id: u32,
    interface: *const wayland.protocol.schema.Interface,
    version: u32,
    metadata: *const wayland.protocol.schema.Message,
    payload: []const u8,
    descriptors: []sys.fd.Descriptor,

    pub fn borrowedDecoder(
        self: *const RoutedView,
    ) wayland.protocol.value.DecodeError!wayland.protocol.value.Decoder {
        return .init(self.metadata, self.payload, self.descriptors);
    }

    pub fn takeDescriptor(
        self: *RoutedView,
        index: usize,
    ) error{ InvalidIndex, DescriptorAlreadyTaken }!sys.fd.Descriptor {
        if (index >= self.descriptors.len) return error.InvalidIndex;
        const descriptor = self.descriptors[index];
        if (descriptor < 0) return error.DescriptorAlreadyTaken;
        self.descriptors[index] = -1;
        return descriptor;
    }
};

test "routed messages transfer descriptor ownership explicitly" {
    const metadata = &wayland.protocol.core.wl_keyboard.events.keymap;
    const pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(pipe[0]);

    const payload = [_]u8{ 1, 0, 0, 0, 8, 0, 0, 0 };
    var descriptors = [_]sys.fd.Descriptor{pipe[1]};
    var routed: RoutedView = .{
        .object_id = 2,
        .interface = &wayland.protocol.core.wl_keyboard.metadata,
        .version = 1,
        .metadata = metadata,
        .payload = &payload,
        .descriptors = &descriptors,
    };

    var decoder = try routed.borrowedDecoder();
    try std.testing.expectEqual(@as(u32, 1), try decoder.unsigned());
    try std.testing.expectEqual(pipe[1], try decoder.descriptor());
    try std.testing.expectEqual(@as(u32, 8), try decoder.unsigned());
    try decoder.finish();
    const taken = try routed.takeDescriptor(0);
    defer sys.fd.close(taken);
    try std.testing.expectError(error.DescriptorAlreadyTaken, routed.takeDescriptor(0));
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.write(taken, "x"));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.read(pipe[0], &byte));
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);
}

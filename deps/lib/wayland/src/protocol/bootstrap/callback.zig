const protocol = @import("../root.zig");

const core = protocol.core.wl_callback;

pub const Done = struct {
    data: u32,
};

pub fn decodeEvent(
    opcode: u16,
    payload: []const u8,
    descriptors: []const @import("sys").fd.Descriptor,
) !Done {
    const metadata = core.metadata.event(opcode) orelse return error.UnknownOpcode;
    var decoder = try protocol.value.Decoder.init(metadata, payload, descriptors);
    const done: Done = .{ .data = try decoder.unsigned() };
    try decoder.finish();
    return done;
}

test "callback done is a typed one-word event" {
    const std = @import("std");

    const payload = [_]u8{ 17, 0, 0, 0 };
    try std.testing.expectEqual(@as(u32, 17), (try decodeEvent(0, &payload, &.{})).data);
    try std.testing.expectError(error.UnknownOpcode, decodeEvent(1, &payload, &.{}));
}

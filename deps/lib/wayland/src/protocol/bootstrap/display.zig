const protocol = @import("../root.zig");

const core = protocol.core.wl_display;

pub const Sync = struct {
    callback: protocol.value.NewId,

    pub fn encode(self: Sync, encoder: *protocol.value.Encoder) !protocol.value.Encoded {
        encoder.reset();
        errdefer encoder.reset();
        try encoder.newId(self.callback);
        return encoder.finish(&core.requests.sync);
    }
};

pub const GetRegistry = struct {
    registry: protocol.value.NewId,

    pub fn encode(self: GetRegistry, encoder: *protocol.value.Encoder) !protocol.value.Encoded {
        encoder.reset();
        errdefer encoder.reset();
        try encoder.newId(self.registry);
        return encoder.finish(&core.requests.get_registry);
    }
};

pub const Fatal = struct {
    object_id: protocol.value.ObjectId,
    code: u32,
    message: []const u8,
};

pub const DeleteId = struct {
    id: u32,
};

pub const Event = union(enum) {
    fatal: Fatal,
    delete_id: DeleteId,
};

pub fn decodeEvent(
    opcode: u16,
    payload: []const u8,
    descriptors: []const @import("sys").fd.Descriptor,
) !Event {
    const metadata = core.metadata.event(opcode) orelse return error.UnknownOpcode;
    var decoder = try protocol.value.Decoder.init(metadata, payload, descriptors);
    const event: Event = switch (opcode) {
        core.events.@"error".opcode => .{ .fatal = .{
            .object_id = try decoder.object(),
            .code = try decoder.unsigned(),
            .message = try decoder.string(),
        } },
        core.events.delete_id.opcode => .{ .delete_id = .{
            .id = try decoder.unsigned(),
        } },
        else => unreachable,
    };
    try decoder.finish();
    return event;
}

test "display bootstrap requests use generated opcodes" {
    const std = @import("std");

    var encoder = try protocol.value.Encoder.init(
        std.testing.allocator,
        protocol.value.default_encoder_capacity,
    );
    defer encoder.deinit();
    const callback = try (Sync{ .callback = try .init(2) }).encode(&encoder);
    try std.testing.expectEqual(@as(u16, 0), callback.opcode());
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, callback.payload);
    const registry = try (GetRegistry{ .registry = try .init(3) }).encode(&encoder);
    try std.testing.expectEqual(@as(u16, 1), registry.opcode());
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0 }, registry.payload);
}

test "display events reject malformed payloads" {
    const std = @import("std");

    const delete_payload = [_]u8{ 9, 0, 0, 0 };
    const event = try decodeEvent(core.events.delete_id.opcode, &delete_payload, &.{});
    try std.testing.expectEqual(@as(u32, 9), event.delete_id.id);
    try std.testing.expectError(error.UnknownOpcode, decodeEvent(9, &.{}, &.{}));
    try std.testing.expectError(
        error.PayloadTooSmall,
        decodeEvent(core.events.@"error".opcode, &delete_payload, &.{}),
    );
}

const protocol = @import("../root.zig");

const core = protocol.core.wl_registry;

pub const Bind = struct {
    name: u32,
    interface: []const u8,
    version: u32,
    id: protocol.value.NewId,

    pub fn encode(self: Bind, encoder: *protocol.value.Encoder) !protocol.value.Encoded {
        encoder.reset();
        errdefer encoder.reset();
        try encoder.unsigned(self.name);
        try encoder.dynamicNewId(self.interface, self.version, self.id);
        return encoder.finish(&core.requests.bind);
    }
};

pub const Global = struct {
    name: u32,
    interface: []const u8,
    version: u32,
};

pub const GlobalRemove = struct {
    name: u32,
};

pub const Event = union(enum) {
    global: Global,
    global_remove: GlobalRemove,
};

pub fn decodeEvent(
    opcode: u16,
    payload: []const u8,
    descriptors: []const @import("sys").fd.Descriptor,
) !Event {
    const metadata = core.metadata.event(opcode) orelse return error.UnknownOpcode;
    var decoder = try protocol.value.Decoder.init(metadata, payload, descriptors);
    const event: Event = switch (opcode) {
        core.events.global.opcode => .{ .global = .{
            .name = try decoder.unsigned(),
            .interface = try decoder.string(),
            .version = try decoder.unsigned(),
        } },
        core.events.global_remove.opcode => .{ .global_remove = .{
            .name = try decoder.unsigned(),
        } },
        else => unreachable,
    };
    try decoder.finish();
    return event;
}

test "registry bind expands its dynamic new_id from XML wire meaning" {
    const std = @import("std");

    var encoder = try protocol.value.Encoder.init(
        std.testing.allocator,
        protocol.value.default_encoder_capacity,
    );
    defer encoder.deinit();
    const encoded = try (Bind{
        .name = 7,
        .interface = "wl_compositor",
        .version = 6,
        .id = try .init(4),
    }).encode(&encoder);
    try std.testing.expectEqualStrings("usun", encoded.metadata.signature);
    var decoder = try protocol.value.Decoder.init(encoded.metadata, encoded.payload, encoded.descriptors);
    try std.testing.expectEqual(@as(u32, 7), try decoder.unsigned());
    const created = try decoder.dynamicNewId();
    try std.testing.expectEqualStrings("wl_compositor", created.interface);
    try std.testing.expectEqual(@as(u32, 6), created.version);
    try std.testing.expectEqual(@as(u32, 4), created.id.raw);
    try decoder.finish();
}

test "registry global event decodes borrowed protocol text" {
    const std = @import("std");

    var encoder = try protocol.value.Encoder.init(
        std.testing.allocator,
        protocol.value.default_encoder_capacity,
    );
    defer encoder.deinit();
    try encoder.unsigned(11);
    try encoder.string("wl_seat");
    try encoder.unsigned(9);
    const encoded = try encoder.finish(&core.events.global);
    const event = try decodeEvent(encoded.opcode(), encoded.payload, encoded.descriptors);
    try std.testing.expectEqual(@as(u32, 11), event.global.name);
    try std.testing.expectEqualStrings("wl_seat", event.global.interface);
    try std.testing.expectEqual(@as(u32, 9), event.global.version);
}

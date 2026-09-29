const decode = @import("decode.zig");
const protocol = @import("../root.zig");

pub fn message(
    metadata: *const protocol.schema.Message,
    payload: []const u8,
    descriptors: []const @import("sys").fd.Descriptor,
) decode.Error!void {
    var decoder = try decode.Decoder.init(metadata, payload, descriptors);
    var optional = false;
    for (metadata.signature) |symbol| switch (symbol) {
        '0'...'9' => {},
        '?' => optional = true,
        'i' => {
            _ = try decoder.signed();
            optional = false;
        },
        'u' => {
            _ = try decoder.unsigned();
            optional = false;
        },
        'f' => {
            _ = try decoder.fixed();
            optional = false;
        },
        's' => {
            if (optional) {
                _ = try decoder.optionalString();
            } else {
                _ = try decoder.string();
            }
            optional = false;
        },
        'o' => {
            if (optional) {
                _ = try decoder.optionalObject();
            } else {
                _ = try decoder.object();
            }
            optional = false;
        },
        'n' => {
            _ = try decoder.newId();
            optional = false;
        },
        'a' => {
            _ = try decoder.array();
            optional = false;
        },
        'h' => {
            _ = try decoder.descriptor();
            optional = false;
        },
        else => unreachable,
    };
    if (optional) unreachable;
    try decoder.finish();
}

test "generic validation follows expanded scanner signatures" {
    const std = @import("std");
    const encode = @import("encode.zig");
    const bind = &protocol.core.wl_registry.requests.bind;
    var encoder = try encode.Encoder.init(std.testing.allocator, encode.default_capacity);
    defer encoder.deinit();
    try encoder.unsigned(4);
    try encoder.dynamicNewId("wl_output", 3, try .init(9));
    const encoded = try encoder.finish(bind);
    try message(bind, encoded.payload, encoded.descriptors);

    try std.testing.expectError(
        error.IncompletePayload,
        message(bind, encoded.payload[0 .. encoded.payload.len - 4], encoded.descriptors),
    );
}

test "generic validation applies nullable wire modifiers" {
    const metadata: protocol.schema.Message = .{
        .name = "nullable",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "?s?o",
        .descriptor_count = 0,
        .minimum_payload_size = 8,
        .arguments = &.{},
    };
    try message(&metadata, &(@as([8]u8, @splat(0))), &.{});
}

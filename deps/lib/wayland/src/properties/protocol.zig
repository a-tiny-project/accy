const std = @import("std");
const hypothesis = @import("hypothesis");
const wayland = @import("wayland");

const protocol = wayland.protocol;

fn settings(seed: u64) hypothesis.Settings {
    return hypothesis.Settings.quick()
        .withSeed(seed)
        .withDatabase("zig-out/hypothesis-failures/wayland-protocol");
}

const ValueRoundTrip = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        const signed: i32 = @bitCast(@as(u32, @intCast(try data.drawInteger(
            0,
            std.math.maxInt(u32),
            0,
        ))));
        const unsigned: u32 = @intCast(try data.drawInteger(0, std.math.maxInt(u32), 0));
        const fixed_raw: i32 = @bitCast(@as(u32, @intCast(try data.drawInteger(
            0,
            std.math.maxInt(u32),
            0,
        ))));
        const object_raw: u32 = @intCast(try data.drawInteger(1, std.math.maxInt(u32), 1));
        const new_raw: u32 = @intCast(try data.drawInteger(1, std.math.maxInt(u32), 1));
        const descriptor: i32 = @intCast(try data.drawInteger(0, std.math.maxInt(i31), 0));
        const version: u32 = @intCast(try data.drawInteger(1, std.math.maxInt(u16), 1));
        const text_len: usize = @intCast(try data.drawInteger(0, 48, 0));
        const text_source = try data.drawBytes(text_len, text_len);
        const text = try allocator.alloc(u8, text_len);
        defer allocator.free(text);
        for (text, text_source) |*destination, source| destination.* = 'a' + source % 26;
        const array_len: usize = @intCast(try data.drawInteger(0, 64, 0));
        const array = try data.drawBytes(array_len, array_len);
        const optional_is_null = try data.drawBoolean();

        const metadata: protocol.schema.Message = .{
            .name = "property",
            .opcode = 5,
            .since = 1,
            .deprecated_since = null,
            .destructor = false,
            .signature = "iuf?sosunah",
            .descriptor_count = 1,
            .minimum_payload_size = 52,
            .arguments = &.{},
        };
        const capacity = protocol.value.default_encoder_capacity;
        var encoder = try protocol.value.Encoder.init(allocator, capacity);
        defer encoder.deinit();
        try encoder.signed(signed);
        try encoder.unsigned(unsigned);
        try encoder.fixed(.fromRaw(fixed_raw));
        try encoder.optionalString(if (optional_is_null) null else text);
        try encoder.object(try .init(object_raw));
        try encoder.optionalObject(null);
        try encoder.dynamicNewId("wl_property", version, try .init(new_raw));
        try encoder.array(array);
        try encoder.descriptorBorrowed(descriptor);
        const encoded = try encoder.finish(&metadata);

        var decoder = try protocol.value.Decoder.init(encoded.metadata, encoded.payload, encoded.descriptors);
        try std.testing.expectEqual(signed, try decoder.signed());
        try std.testing.expectEqual(unsigned, try decoder.unsigned());
        try std.testing.expectEqual(fixed_raw, (try decoder.fixed()).raw);
        const decoded_optional = try decoder.optionalString();
        if (optional_is_null) {
            try std.testing.expect(decoded_optional == null);
        } else {
            try std.testing.expectEqualSlices(u8, text, decoded_optional.?);
        }
        try std.testing.expectEqual(object_raw, (try decoder.object()).raw);
        try std.testing.expect((try decoder.optionalObject()) == null);
        const dynamic = try decoder.dynamicNewId();
        try std.testing.expectEqualStrings("wl_property", dynamic.interface);
        try std.testing.expectEqual(version, dynamic.version);
        try std.testing.expectEqual(new_raw, dynamic.id.raw);
        try std.testing.expectEqualSlices(u8, array, try decoder.array());
        try std.testing.expectEqual(descriptor, try decoder.descriptor());
        try decoder.finish();
    }
};

test "property: every Wayland value form round trips" {
    try hypothesis.checkNamed(
        ValueRoundTrip,
        "wayland-value-round-trip",
        settings(0x5741_594c_414e_4411),
    );
}

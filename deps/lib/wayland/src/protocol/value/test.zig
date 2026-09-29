const std = @import("std");
const value = @import("root.zig");

const Decoder = value.Decoder;
const Encoder = value.Encoder;
const Fixed = value.Fixed;
const NewId = value.NewId;
const ObjectId = value.ObjectId;
const default_encoder_capacity = value.default_encoder_capacity;

test "typed protocol value namespace is complete" {
    std.testing.refAllDecls(value);
}

test "all Wayland argument forms round trip with independent descriptors" {
    const sys = @import("sys");
    const protocol = @import("../root.zig");

    const arguments = [_]protocol.schema.Argument{
        .{ .name = "signed", .kind = .int, .interface = null, .enumeration = null, .nullable = false },
        .{ .name = "unsigned", .kind = .uint, .interface = null, .enumeration = null, .nullable = false },
        .{ .name = "fixed", .kind = .fixed, .interface = null, .enumeration = null, .nullable = false },
        .{ .name = "string", .kind = .string, .interface = null, .enumeration = null, .nullable = false },
        .{ .name = "nullable", .kind = .string, .interface = null, .enumeration = null, .nullable = true },
        .{ .name = "object", .kind = .object, .interface = null, .enumeration = null, .nullable = false },
        .{ .name = "optional", .kind = .object, .interface = null, .enumeration = null, .nullable = true },
        .{ .name = "new", .kind = .new_id, .interface = "made", .enumeration = null, .nullable = false },
        .{ .name = "array", .kind = .array, .interface = null, .enumeration = null, .nullable = false },
        .{ .name = "descriptor", .kind = .fd, .interface = null, .enumeration = null, .nullable = false },
    };
    const metadata: protocol.schema.Message = .{
        .name = "all",
        .opcode = 3,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "iufs?sonah",
        .descriptor_count = 1,
        .minimum_payload_size = 44,
        .arguments = &arguments,
    };
    const descriptor: sys.fd.Descriptor = 37;
    var encoder = try Encoder.init(std.testing.allocator, default_encoder_capacity);
    defer encoder.deinit();
    try encoder.signed(-17);
    try encoder.unsigned(42);
    try encoder.fixed(Fixed.fromRaw(-129));
    try encoder.string("hello");
    try encoder.optionalString(null);
    try encoder.object(try ObjectId.init(9));
    try encoder.optionalObject(null);
    try encoder.newId(try NewId.init(10));
    try encoder.array(&.{ 1, 2, 3, 4, 5 });
    try encoder.descriptorBorrowed(descriptor);
    const encoded = try encoder.finish(&metadata);

    var decoder = try Decoder.init(encoded.metadata, encoded.payload, encoded.descriptors);
    try std.testing.expectEqual(@as(i32, -17), try decoder.signed());
    try std.testing.expectEqual(@as(u32, 42), try decoder.unsigned());
    try std.testing.expectEqual(@as(i32, -129), (try decoder.fixed()).raw);
    try std.testing.expectEqualStrings("hello", try decoder.string());
    try std.testing.expect((try decoder.optionalString()) == null);
    try std.testing.expectEqual(@as(u32, 9), (try decoder.object()).raw);
    try std.testing.expect((try decoder.optionalObject()) == null);
    try std.testing.expectEqual(@as(u32, 10), (try decoder.newId()).raw);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, try decoder.array());
    try std.testing.expectEqual(descriptor, try decoder.descriptor());
    try decoder.finish();
}

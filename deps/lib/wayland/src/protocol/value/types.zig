const std = @import("std");
const sys = @import("sys");
const protocol = @import("../root.zig");

pub const maximum_payload_size = (std.math.maxInt(u16) & ~@as(u16, 3)) - 8;

pub const ObjectId = struct {
    raw: u32,

    pub fn init(raw: u32) error{InvalidObject}!ObjectId {
        if (raw == 0) return error.InvalidObject;
        return .{ .raw = raw };
    }
};

pub const NewId = struct {
    raw: u32,

    pub fn init(raw: u32) error{InvalidNewId}!NewId {
        if (raw == 0) return error.InvalidNewId;
        return .{ .raw = raw };
    }
};

pub const Fixed = struct {
    raw: i32,

    pub fn fromRaw(raw: i32) Fixed {
        return .{ .raw = raw };
    }

    pub fn fromInt(value: i32) error{Overflow}!Fixed {
        return .{ .raw = std.math.mul(i32, value, 256) catch return error.Overflow };
    }

    pub fn toF64(self: Fixed) f64 {
        return @as(f64, @floatFromInt(self.raw)) / 256.0;
    }
};

pub const DynamicNewId = struct {
    interface: []const u8,
    version: u32,
    id: NewId,
};

pub const Encoded = struct {
    metadata: *const protocol.schema.Message,
    payload: []const u8,
    descriptors: []const sys.fd.Descriptor,

    pub fn opcode(self: Encoded) u16 {
        return self.metadata.opcode;
    }
};

test "nominal object values reject the wire null sentinel" {
    try std.testing.expectError(error.InvalidObject, ObjectId.init(0));
    try std.testing.expectError(error.InvalidNewId, NewId.init(0));
    try std.testing.expectEqual(@as(u32, 9), (try ObjectId.init(9)).raw);
    try std.testing.expectEqual(@as(u32, 10), (try NewId.init(10)).raw);
}

test "fixed values preserve 24.8 protocol units" {
    try std.testing.expectEqual(@as(i32, -512), (try Fixed.fromInt(-2)).raw);
    try std.testing.expectEqual(@as(f64, 1.5), Fixed.fromRaw(384).toF64());
    try std.testing.expectError(error.Overflow, Fixed.fromInt(std.math.maxInt(i32)));
}

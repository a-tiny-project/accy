const std = @import("std");
const builtin = @import("builtin");

pub const header_size = 8;
pub const maximum_message_size = std.math.maxInt(u16) & ~@as(u16, 3);

pub const Error = error{
    IncompleteHeader,
    InvalidObject,
    InvalidSize,
    MessageTooLarge,
};

pub const Header = struct {
    object_id: u32,
    opcode: u16,
    size: u16,

    pub fn init(object_id: u32, opcode: u16, payload_size: usize) Error!Header {
        if (object_id == 0) return error.InvalidObject;
        if (payload_size % 4 != 0) return error.InvalidSize;
        if (payload_size > maximum_message_size - header_size) return error.MessageTooLarge;
        const size = header_size + payload_size;
        return .{
            .object_id = object_id,
            .opcode = opcode,
            .size = @intCast(size),
        };
    }

    pub fn encode(self: Header, destination: *[header_size]u8) Error!void {
        try self.validate();
        const second = @as(u32, self.size) << 16 | self.opcode;
        std.mem.writeInt(u32, destination[0..4], self.object_id, builtin.cpu.arch.endian());
        std.mem.writeInt(u32, destination[4..8], second, builtin.cpu.arch.endian());
    }

    pub fn validate(self: Header) Error!void {
        if (self.object_id == 0) return error.InvalidObject;
        if (self.size < header_size or self.size % 4 != 0) return error.InvalidSize;
    }
};

pub fn decode(bytes: []const u8) Error!Header {
    if (bytes.len < header_size) return error.IncompleteHeader;
    const second = std.mem.readInt(u32, bytes[4..8], builtin.cpu.arch.endian());
    const header: Header = .{
        .object_id = std.mem.readInt(u32, bytes[0..4], builtin.cpu.arch.endian()),
        .opcode = @truncate(second),
        .size = @intCast(second >> 16),
    };
    try header.validate();
    return header;
}

test "Wayland header round trips in host byte order" {
    const expected: Header = .{ .object_id = 0x1234, .opcode = 7, .size = 20 };
    var encoded: [header_size]u8 = undefined;
    try expected.encode(&encoded);
    try std.testing.expectEqual(expected, try decode(&encoded));
}

test "Wayland header rejects invalid object and size fields" {
    try std.testing.expectError(error.InvalidObject, Header.init(0, 0, 0));
    try std.testing.expectError(error.InvalidSize, Header.init(1, 0, 2));
    try std.testing.expectError(error.MessageTooLarge, Header.init(1, 0, maximum_message_size));

    var encoded: [header_size]u8 = @splat(0);
    std.mem.writeInt(u32, encoded[0..4], 1, builtin.cpu.arch.endian());
    std.mem.writeInt(u32, encoded[4..8], @as(u32, 6) << 16, builtin.cpu.arch.endian());
    try std.testing.expectError(error.InvalidSize, decode(&encoded));
}

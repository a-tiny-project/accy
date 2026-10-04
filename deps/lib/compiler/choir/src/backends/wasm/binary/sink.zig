const std = @import("std");

pub const Count = struct {
    len: usize = 0,

    pub fn writeByte(self: *Count, _: u8) error{CapacityOverflow}!void {
        self.len = std.math.add(usize, self.len, 1) catch return error.CapacityOverflow;
    }

    pub fn writeAll(self: *Count, bytes: []const u8) error{CapacityOverflow}!void {
        self.len = std.math.add(usize, self.len, bytes.len) catch return error.CapacityOverflow;
    }
};

pub const Fixed = struct {
    bytes: []u8,
    len: usize = 0,

    pub fn init(bytes: []u8) Fixed {
        return .{ .bytes = bytes };
    }

    pub fn writeByte(self: *Fixed, byte: u8) error{OutputOverflow}!void {
        if (self.len == self.bytes.len) return error.OutputOverflow;
        self.bytes[self.len] = byte;
        self.len += 1;
    }

    pub fn writeAll(self: *Fixed, bytes: []const u8) error{OutputOverflow}!void {
        const end = std.math.add(usize, self.len, bytes.len) catch return error.OutputOverflow;
        if (end > self.bytes.len) return error.OutputOverflow;
        @memcpy(self.bytes[self.len..end], bytes);
        self.len = end;
    }

    pub fn finish(self: *const Fixed) error{OutputUnderflow}![]u8 {
        if (self.len != self.bytes.len) return error.OutputUnderflow;
        return self.bytes;
    }
};

test "wasm binary fixed sink requires the exact output capacity" {
    var bytes: [2]u8 = undefined;
    var fixed = Fixed.init(&bytes);
    try fixed.writeByte(1);
    try std.testing.expectError(error.OutputUnderflow, fixed.finish());
    try fixed.writeByte(2);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, try fixed.finish());
    try std.testing.expectError(error.OutputOverflow, fixed.writeByte(3));
}

const std = @import("std");

pub fn Repeated(comptime capacity: usize) type {
    if (capacity == 0) @compileError("repeated command capacity must be positive");
    return struct {
        pub const command_repeated = true;

        values: [capacity][]const u8 = undefined,
        len: usize = 0,

        pub fn append(self: *@This(), value: []const u8) error{TooManyValues}!void {
            if (self.len >= capacity) return error.TooManyValues;
            self.values[self.len] = value;
            self.len += 1;
        }

        pub fn slice(self: *const @This()) []const []const u8 {
            std.debug.assert(self.len <= capacity);
            return self.values[0..self.len];
        }
    };
}

test "repeated command values use fixed caller storage" {
    var values: Repeated(2) = .{};
    try values.append("one");
    try values.append("two");
    try std.testing.expectEqualSlices([]const u8, &.{ "one", "two" }, values.slice());
    try std.testing.expectError(error.TooManyValues, values.append("three"));
}

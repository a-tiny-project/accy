const std = @import("std");

pub fn Filters(comptime max_count: usize) type {
    return struct {
        values: [max_count][]const u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn add(self: *Self, value: []const u8) void {
            if (value.len == 0) return;
            if (self.len >= self.values.len) @panic("too many test filters");
            self.values[self.len] = value;
            self.len += 1;
        }

        pub fn match(self: *const Self, name: []const u8) bool {
            if (self.len == 0) return true;
            for (self.values[0..self.len]) |needle| {
                if (std.mem.indexOf(u8, name, needle) != null) return true;
            }
            return false;
        }
    };
}

pub fn Selection(comptime Filter: type) type {
    return struct {
        includes: Filter,
        excludes: Filter,

        const Self = @This();

        pub fn match(self: *const Self, name: []const u8) bool {
            return self.includes.match(name) and
                (self.excludes.len == 0 or !self.excludes.match(name));
        }
    };
}

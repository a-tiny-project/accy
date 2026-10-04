const std = @import("std");
const payload = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const TextDump = struct {
    name: []const u8,
    contents: []const u8,

    pub fn dupe(self: TextDump, allocator: Allocator) Allocator.Error!TextDump {
        const name = try payload.slice.dupe(allocator, self.name);
        errdefer payload.slice.free(allocator, name);
        return .{
            .name = name,
            .contents = try payload.slice.dupe(allocator, self.contents),
        };
    }

    pub fn deinit(self: TextDump, allocator: Allocator) void {
        payload.slice.free(allocator, self.name);
        payload.slice.free(allocator, self.contents);
    }

    pub fn eql(self: TextDump, other: TextDump) bool {
        return std.mem.eql(u8, self.name, other.name) and
            std.mem.eql(u8, self.contents, other.contents);
    }
};

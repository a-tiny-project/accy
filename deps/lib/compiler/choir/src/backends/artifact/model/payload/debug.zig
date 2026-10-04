const std = @import("std");
const payload = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const DebugRecordKind = enum(u8) {
    line_table = 1,
    symbol_table = 2,
    dwarf_section = 3,
    source_map = 4,
    note = 5,
};

pub const DebugRecord = struct {
    name: []const u8,
    kind: DebugRecordKind,
    bytes: []const u8,

    pub fn dupe(self: DebugRecord, allocator: Allocator) Allocator.Error!DebugRecord {
        const name = try payload.slice.dupe(allocator, self.name);
        errdefer payload.slice.free(allocator, name);
        return .{
            .name = name,
            .kind = self.kind,
            .bytes = try payload.slice.dupe(allocator, self.bytes),
        };
    }

    pub fn deinit(self: DebugRecord, allocator: Allocator) void {
        payload.slice.free(allocator, self.name);
        payload.slice.free(allocator, self.bytes);
    }

    pub fn eql(self: DebugRecord, other: DebugRecord) bool {
        return self.kind == other.kind and
            std.mem.eql(u8, self.name, other.name) and
            std.mem.eql(u8, self.bytes, other.bytes);
    }
};

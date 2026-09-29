const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Table = struct {
    data: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: Allocator) Allocator.Error!Table {
        var table = Table{};
        try table.data.append(allocator, 0);
        return table;
    }

    pub fn deinit(self: *Table, allocator: Allocator) void {
        self.data.deinit(allocator);
    }

    pub fn add(self: *Table, allocator: Allocator, value: []const u8) Allocator.Error!u32 {
        const offset: u32 = @intCast(self.data.items.len);
        try self.data.appendSlice(allocator, value);
        try self.data.append(allocator, 0);
        return offset;
    }

    pub fn bytes(self: Table) []const u8 {
        return self.data.items;
    }
};

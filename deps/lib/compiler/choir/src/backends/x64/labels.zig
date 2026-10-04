const std = @import("std");

pub const Label = struct {
    offset: ?u32 = null,
    fixups: std.ArrayListUnmanaged(u32) = .empty,

    pub fn deinit(self: *Label, allocator: std.mem.Allocator) void {
        self.fixups.deinit(allocator);
    }
};

const std = @import("std");

pub const Label = struct {
    offset: ?u32 = null,
    fixups: std.ArrayListUnmanaged(u32) = .empty,

    pub fn deinit(self: *Label, allocator: std.mem.Allocator) void {
        self.fixups.deinit(allocator);
    }
};

test "label starts unbound" {
    const testing = @import("std").testing;

    var label = Label{};
    defer label.deinit(testing.allocator);
    try testing.expect(label.offset == null);
    try testing.expectEqual(@as(usize, 0), label.fixups.items.len);
}

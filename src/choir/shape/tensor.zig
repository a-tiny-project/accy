const expression = @import("expression.zig");

pub const Tensor = struct {
    name: []const u8,
    extents: []const expression.Expression,

    pub fn rank(self: Tensor) usize {
        return self.extents.len;
    }
};

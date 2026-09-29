const builder = @import("../../core/root.zig").builder;

pub fn Guard(comptime Owner: type) type {
    return struct {
        owner: *Owner,
        previous: builder.Block,
        else_block: builder.Block,
        active: bool = true,

        pub fn leave(self: *@This()) !void {
            if (!self.active) return;
            errdefer self.owner.setInsertionBlock(self.previous);
            try self.owner.yield_(&.{});
            self.owner.setInsertionBlock(self.else_block);
            try self.owner.yield_(&.{});
            self.owner.setInsertionBlock(self.previous);
            self.active = false;
        }

        pub fn abort(self: *@This()) void {
            if (!self.active) return;
            self.owner.setInsertionBlock(self.previous);
            self.active = false;
        }
    };
}

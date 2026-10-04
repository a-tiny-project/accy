const std = @import("std");
const ir = @import("../core/root.zig");
const rewrite = ir.rewrite;

pub const RewriteBuilder = struct {
    rewriter: rewrite.PatternRewriter,
    root: *ir.Operation,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *ir.Context,
        root: *ir.Operation,
    ) RewriteBuilder {
        return .{
            .rewriter = rewrite.PatternRewriter.init(allocator, ctx),
            .root = root,
        };
    }

    pub fn deinit(self: *RewriteBuilder) void {
        self.rewriter.deinit();
    }

    pub fn finalize(self: *RewriteBuilder) void {
        self.rewriter.finalize(self.root);
    }

    pub fn setInsertionPointBefore(self: *RewriteBuilder, op: *ir.Operation) void {
        self.rewriter.setInsertionPointBefore(op);
    }

    pub fn setInsertionPointAfter(self: *RewriteBuilder, op: *ir.Operation) void {
        self.rewriter.setInsertionPointAfter(op);
    }

    pub fn hasInsertionPoint(self: *const RewriteBuilder) bool {
        return self.rewriter.hasInsertionPoint();
    }

    pub fn create(self: *RewriteBuilder, state: ir.Operation.State) !*ir.Operation {
        return self.rewriter.create(state);
    }

    pub fn replaceOp(self: *RewriteBuilder, op: *ir.Operation, new_values: []const *ir.Value) !void {
        try self.rewriter.replaceOp(op, new_values);
    }

    pub fn replaceOpWithValue(self: *RewriteBuilder, op: *ir.Operation, new_value: *ir.Value) !void {
        try self.rewriter.replaceOpWithValue(op, new_value);
    }

    pub fn eraseOp(self: *RewriteBuilder, op: *ir.Operation) !void {
        try self.rewriter.eraseOp(op);
    }

    pub fn setAttr(self: *RewriteBuilder, op: *ir.Operation, key: []const u8, value: ir.Attribute) !void {
        try self.rewriter.setAttr(op, key, value);
    }
};

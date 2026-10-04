const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");

pub const BuiltinDialect = struct {
    pub const name = "builtin";
    const op_templates = ir.dialects.operationTemplate.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{});

    pub const ModuleOp = struct {
        op: *ir.Operation,

        const def = op_templates.explicit(@This(), .{
            .mnemonic = "module",
            .operands = 0,
            .results = 0,
            .regions = .{"body"},
            .successors = 0,
            .dynamic_traits = .{ ir.traits.SymbolTable, ir.traits.IsolatedFromAbove, ir.traits.NoTerminator, ir.traits.SingleBlock },
        });
        pub const operation_spec = def.operation_spec;
        pub const operation_name = def.operation_name;
        pub const createOperation = def.createOperation;
        pub const getRegion = def.getRegion;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !ModuleOp {
            try loadSpec(ctx);
            var body = ir.context.initRegion(ctx);
            defer body.deinit();
            var body_builder = ir.OperationBuilder.init(ctx);
            _ = try body_builder.createBlock(&body, &.{}, &.{});
            return try @This().createOperation(ctx, loc, &.{}, &.{}, &.{&body}, &.{});
        }

        pub fn getBody(self: ModuleOp) *ir.Region {
            return self.getRegion("body");
        }

        pub fn getBodyBlock(self: ModuleOp) *ir.Block {
            return self.getBody().getEntryBlock().?;
        }
    };

    fn loadSpec(ctx: *ir.Context) !void {
        ir.dialects.loadDialectSpec(ctx, spec) catch |err| switch (err) {
            error.ContextFrozen => {},
            else => return err,
        };
    }
};

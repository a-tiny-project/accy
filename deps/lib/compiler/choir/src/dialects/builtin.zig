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

test "BuiltinDialect.ModuleOp creates container with region" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    try testing.expectEqualStrings("builtin.module", module.op.name.name);
    const body = module.getBody();
    try testing.expect(body.getEntryBlock() != null);
    try testing.expect(module.op.hasTraitId(ir.traits.SymbolTable.id));
    try testing.expect(module.op.hasTraitId(ir.traits.IsolatedFromAbove.id));
    try testing.expect(module.op.hasTraitId(ir.traits.NoTerminator.id));
    try testing.expect(module.op.hasTraitId(ir.traits.SingleBlock.id));

    const info = ctx.lookupOperation(BuiltinDialect.ModuleOp.operation_name).?;
    try testing.expect(info.shape.regions.allows(1));
    try testing.expect(!info.shape.regions.allows(0));
    try testing.expect(info.shape.successors.allows(0));
    try testing.expect(!info.shape.successors.allows(1));
}

test "Operations attach to module block" {
    const testing = std.testing;
    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    builder.setInsertionPoint(block);

    const arith = @import("arith/root.zig").ArithDialect;
    const i64_type = try arith.getScalarType(&ctx, .i64);
    var state = ir.Operation.State.init("arith.constant", loc);
    state.addTypes(&.{i64_type});
    const op = try builder.create(state);

    try testing.expect(op.parent_block == block);
    try testing.expect(!block.operations.isEmpty());
    try testing.expect(block.operations.head == @as(?*anyopaque, op));
}

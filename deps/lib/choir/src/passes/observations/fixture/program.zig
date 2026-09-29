const std = @import("std");
const choir = @import("../../../root.zig");
const support = @import("../../../dialects/fixture/root.zig");
const ir = choir.ir;
const passes = choir.passes;
const arith = choir.dialects.ArithDialect;
const dialect = support.TestDialect;
const egraph = choir.egraph;

pub const Fixture = enum {
    canonicalization_select_inverse,
    cse_dominating_and_incomparable_blocks,
    saturation_identity_extraction,
    verifier_yield_type_diagnostic,

    pub fn filename(self: Fixture) []const u8 {
        return switch (self) {
            .canonicalization_select_inverse => "canonicalization.txt",
            .cse_dominating_and_incomparable_blocks => "cse.txt",
            .saturation_identity_extraction => "saturation.txt",
            .verifier_yield_type_diagnostic => "diagnostic.txt",
        };
    }
};

/// Builds the bounded select-inverse, dominating/incomparable CSE, reduction
/// template extraction, and named yield-type verifier cases from the owned tests.
pub fn build(ctx: *ir.Context, fixture: Fixture) !*ir.Operation {
    if (fixture == .verifier_yield_type_diagnostic) return diagnostic(ctx);
    try support.registerTestDialect(ctx);
    return switch (fixture) {
        .canonicalization_select_inverse => canonicalization(ctx),
        .cse_dominating_and_incomparable_blocks => cse(ctx),
        .saturation_identity_extraction => saturation(ctx),
        .verifier_yield_type_diagnostic => unreachable,
    };
}

pub fn addPasses(manager: *passes.PassManager, fixture: Fixture) !void {
    switch (fixture) {
        .canonicalization_select_inverse => try manager.addPass(
            passes.createCanonicalizationPass(),
        ),
        .cse_dominating_and_incomparable_blocks => try manager.addPass(
            passes.createCommonSubexpressionEliminationPass(),
        ),
        .saturation_identity_extraction => try manager.addPass(ReductionPass.create()),
        .verifier_yield_type_diagnostic => {
            manager.enableVerifier();
            try manager.addPass(passes.createCommonSubexpressionEliminationPass());
        },
    }
}

fn canonicalization(ctx: *ir.Context) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const module = try dialect.ModuleOp.create(ctx, loc);
    const block = module.getBodyBlock();
    const condition = try block.addArgument(try arith.getScalarType(ctx, .bool), loc);
    const false_value = try arith.ConstantOp.createBool(ctx, loc, false);
    const true_value = try arith.ConstantOp.createBool(ctx, loc, true);
    try block.addOperation(false_value.op);
    try block.addOperation(true_value.op);
    const select = try arith.SelectOp.create(
        ctx,
        loc,
        condition,
        false_value.getResult(),
        true_value.getResult(),
    );
    try block.addOperation(select.op);
    var state = ir.Operation.State.init("test.user", loc);
    state.addOperands(&.{select.getResult()});
    try block.addOperation(try ctx.createOperation(state));
    return module.op;
}

fn cse(ctx: *ir.Context) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const module = try dialect.ModuleOp.create(ctx, loc);
    const region = module.getBody();
    const entry = module.getBodyBlock();
    const then_block = try region.addBlock();
    const else_block = try region.addBlock();
    const merge = try region.addBlock();
    const ty = try dialect.getI32Type(ctx);
    const lhs = try entry.addArgument(ty, loc);
    const rhs = try entry.addArgument(ty, loc);
    const other = try entry.addArgument(ty, loc);
    const first = try binary(ctx, entry, lhs, rhs);
    try branch(ctx, entry, &.{ then_block, else_block });
    _ = try binary(ctx, then_block, lhs, rhs);
    _ = try binary(ctx, then_block, rhs, other);
    try branch(ctx, then_block, &.{merge});
    _ = try binary(ctx, else_block, rhs, other);
    try branch(ctx, else_block, &.{merge});
    const ret = try dialect.ReturnOp.create(ctx, loc, &.{first.getResult()});
    try merge.addOperation(ret.op);
    return module.op;
}

fn binary(ctx: *ir.Context, block: *ir.Block, lhs: *ir.Value, rhs: *ir.Value) !dialect.BinaryOp {
    const op = try dialect.BinaryOp.create(ctx, .unknown, lhs, rhs);
    try block.addOperation(op.op);
    return op;
}

fn branch(ctx: *ir.Context, block: *ir.Block, successors: []const *ir.Block) !void {
    var state = ir.Operation.State.init("test.br", .unknown);
    state.addSuccessors(successors);
    try block.addOperation(try ctx.createOperation(state));
}

fn saturation(ctx: *ir.Context) !*ir.Operation {
    _ = try ctx.registerOperation("test.constant", .{});
    _ = try ctx.registerOperation("test.binary", .{ .is_commutative = true });
    const loc = ir.Location.getUnknown();
    const module = try dialect.ModuleOp.create(ctx, loc);
    const block = module.getBodyBlock();
    const ty = try dialect.getI64Type(ctx);
    var value = try dialect.ConstantOp.create(ctx, loc, ty, 7);
    var two = try dialect.ConstantOp.create(ctx, loc, ty, 2);
    try block.addOperation(value.op);
    try block.addOperation(two.op);
    const double = try binary(ctx, block, value.getResult(), two.getResult());
    const ret = try dialect.ReturnOp.create(ctx, loc, &.{double.getResult()});
    try block.addOperation(ret.op);
    return module.op;
}

fn candidate(_: ?*anyopaque, op: *ir.Operation) anyerror!bool {
    return std.mem.eql(u8, op.name.name, "test.constant") or
        std.mem.eql(u8, op.name.name, "test.binary");
}

fn classify(ty: ir.Type) egraph.TypeClass {
    const name = ty.getDialectTypeName() orelse return .other;
    return if (std.mem.eql(u8, name, "test.i64")) .integer else .other;
}

fn readScalar(attr: ir.Attribute) ?egraph.Scalar {
    return .{ .int = dialect.getIntegerValue(attr) orelse return null };
}

fn buildScalar(ctx: *ir.Context, value: egraph.Scalar) anyerror!ir.Attribute {
    return switch (value) {
        .int => |number| dialect.getIntegerAttr(ctx, number),
        else => error.UnsupportedScalar,
    };
}

fn reductionRules(rules: *egraph.RewriteSet) anyerror!void {
    rules.setConstantModel(.{
        .op_name = "test.constant",
        .classify = classify,
        .read = readScalar,
        .build = buildScalar,
    });
    rules.setCostModel(.{ .overrides = &.{.{ .name = "test.identity", .cost = 1 }} });
    try rules.addPattern(.{
        .name = "test-binary-double-to-identity",
        .benefit = 10,
        .classes = &.{.integer},
        .lhs = .{
            .name = "test.binary",
            .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 2 } } },
        },
        .rhs = .{ .operation = .{ .name = "test.identity", .operands = &.{.{ .variable = 0 }} } },
    });
}

const ReductionPass = passes.EGraphPass(.{
    .name = "choir-egraph-reduction-test",
    .description = "test egraph operation materialization pass",
    .populate_rules = reductionRules,
    .options = .{ .candidate = candidate },
});

fn diagnostic(ctx: *ir.Context) !*ir.Operation {
    try ir.dialects.loadDialectSpec(ctx, choir.dialects.BuiltinDialect.spec);
    try ir.dialects.loadDialectSpec(ctx, choir.dialects.arith.spec);
    try ir.dialects.loadDialectSpec(ctx, choir.dialects.ScfDialect.spec);
    return ir.parse.source(ctx, .{ .name = "wrong-yield.choir", .text =
        \\builtin.module() {
        \\  ^bb0(%0: !arith.index):
        \\    %1 = arith.constant() {value = 0.0:f64}: !arith.f64
        \\    %7 = scf.for(%0, %0, %0, %1): !arith.f64 {
        \\      ^bb1(%4: !arith.index, %5: !arith.f64):
        \\        scf.yield(%0)
        \\    }
        \\}
        \\
    });
}

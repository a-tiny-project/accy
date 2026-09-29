const std = @import("std");
const passes = @import("root.zig");
const cse = @import("cse/test.zig");
const pass_tests = @import("pass/test.zig");
const observations = @import("observations/test.zig");

test {
    _ = cse;
    _ = pass_tests;
    _ = observations;
    std.testing.refAllDecls(passes);
}

const alloc_arena = @import("alloc_arena");
const egraph = @import("../egraph/root.zig");
const ir = @import("../core/root.zig");
const dialects = @import("../dialects/root.zig");
const test_support = @import("../dialects/fixture/root.zig");
const pass_mod = passes.pass;
const arith = dialects.ArithDialect;
const ClassId = egraph.ClassId;
const EGraphPass = passes.EGraphPass;
const Graph = egraph.Graph;
const Node = egraph.Node;
const RewriteContext = egraph.RewriteContext;
const RewriteSet = egraph.RewriteSet;
const Scalar = egraph.Scalar;
const TypeClass = egraph.TypeClass;
fn noRules(_: *RewriteSet) anyerror!void {}

fn testCandidate(_: ?*anyopaque, op: *ir.Operation) anyerror!bool {
    return std.mem.eql(u8, op.name.name, "arith.constant") or
        std.mem.eql(u8, op.name.name, "arith.add");
}

const EmptyTestPass = EGraphPass(.{
    .name = "choir-egraph-empty-test",
    .description = "test egraph pass",
    .populate_rules = noRules,
    .options = .{ .candidate = testCandidate },
});

fn isZeroClass(ctx: *RewriteContext, id: ClassId) bool {
    for (ctx.nodes(id)) |*entry| {
        if (entry.kind != .operation) continue;
        if (!std.mem.eql(u8, entry.op_name, "arith.constant")) continue;
        const attr = entry.getAttr("value") orelse continue;
        const value = arith.getIntValue(attr) orelse continue;
        if (value == 0) return true;
    }
    return false;
}

fn foldBinaryZero(ctx: *RewriteContext, class: ClassId, entry: *const Node) anyerror!bool {
    if (entry.kind != .operation) return false;
    if (!std.mem.eql(u8, entry.op_name, "arith.add")) return false;
    if (entry.operands.len != 2) return false;
    if (isZeroClass(ctx, entry.operands[0])) return try ctx.merge(class, entry.operands[1]);
    if (isZeroClass(ctx, entry.operands[1])) return try ctx.merge(class, entry.operands[0]);
    return false;
}

fn zeroRules(rule_set: *RewriteSet) anyerror!void {
    try rule_set.add(.{
        .name = "test-binary-zero",
        .benefit = 10,
        .apply = foldBinaryZero,
    });
}

const ZeroTestPass = EGraphPass(.{
    .name = "choir-egraph-zero-test",
    .description = "test egraph zero rewrite pass",
    .populate_rules = zeroRules,
    .options = .{ .candidate = testCandidate },
});

const BudgetTestPass = EGraphPass(.{
    .name = "choir-egraph-budget-test",
    .description = "test egraph rewrite budget pass",
    .populate_rules = zeroRules,
    .options = .{ .candidate = testCandidate, .max_rewrites = 1 },
});

fn buildTestContext(allocator: std.mem.Allocator) !ir.Context {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    errdefer ctx.deinit(allocator);
    try test_support.registerTestDialect(&ctx);
    try ir.dialects.loadDialectSpec(&ctx, dialects.arith.spec);
    _ = try ctx.registerOperation("arith.constant", .{});
    _ = try ctx.registerOperation("arith.add", .{ .is_commutative = true });
    return ctx;
}

test "egraph default candidate uses effect summaries" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try ctx.registerOperationInterface(
        "test.effect_free_value",
        ir.interfaces.EffectOpInterface.entryFor(.{}),
    );
    try ctx.registerOperationInterface(
        "test.read_value",
        ir.interfaces.EffectOpInterface.entryFor(.{}),
    );

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.getScalarType(&ctx, .i64);
    var producer_state = ir.Operation.State.init("arith.constant", loc);
    producer_state.addTypes(&.{i64_type});
    const producer = try ctx.createOperation(producer_state);

    var effect_free_state = ir.Operation.State.init("test.effect_free_value", loc);
    effect_free_state.addTypes(&.{i64_type});
    const effect_free = try ctx.createOperation(effect_free_state);

    var read_state = ir.Operation.State.init("test.read_value", loc);
    read_state.addOperands(&.{producer.getResult(0).?});
    read_state.addTypes(&.{i64_type});
    const read = try ctx.createOperation(read_state);

    try testing.expect(!try passes.saturation.defaultCandidate(null, effect_free));
    try testing.expect(!try passes.saturation.defaultCandidate(null, read));
}

test "egraph pass replaces duplicate block-local expressions" {
    const test_dialect = test_support.TestDialect;
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.getScalarType(&ctx, .i64);
    const module = try test_dialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    var lhs = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 7);
    var rhs = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 11);
    var add1 = try arith.AddOp.create(&ctx, loc, lhs.getResult(), rhs.getResult());
    var add2 = try arith.AddOp.create(&ctx, loc, rhs.getResult(), lhs.getResult());
    const ret = try test_dialect.ReturnOp.create(&ctx, loc, &.{add2.getResult()});

    try block.addOperation(lhs.op);
    try block.addOperation(rhs.op);
    try block.addOperation(add1.op);
    try block.addOperation(add2.op);
    try block.addOperation(ret.op);

    var pm = pass_mod.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(EmptyTestPass.create());
    try std.testing.expectEqual(pass_mod.PassResult.success, pm.run(module.op, &ctx));

    try testing.expect(ret.op.getOperand(0).? == add1.getResult());
    try testing.expect(ret.op.prev_op == add1.op);
}

test "egraph rules rewrite expressions to cheaper equivalent values" {
    const test_dialect = test_support.TestDialect;
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.getScalarType(&ctx, .i64);
    const module = try test_dialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    var value = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 7);
    var zero = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 0);
    var add = try arith.AddOp.create(&ctx, loc, value.getResult(), zero.getResult());
    const ret = try test_dialect.ReturnOp.create(&ctx, loc, &.{add.getResult()});

    try block.addOperation(value.op);
    try block.addOperation(zero.op);
    try block.addOperation(add.op);
    try block.addOperation(ret.op);

    var pm = pass_mod.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(ZeroTestPass.create());
    try std.testing.expectEqual(pass_mod.PassResult.success, pm.run(module.op, &ctx));

    try testing.expect(ret.op.getOperand(0).? == value.getResult());
    try testing.expect(ret.op.prev_op == zero.op);
}

fn testClassifyType(ty: ir.Type) TypeClass {
    const name = ty.getDialectTypeName() orelse return .other;
    if (std.mem.eql(u8, name, "arith.i64")) return .integer;
    return .other;
}

fn testReadScalar(attr: ir.Attribute) ?Scalar {
    const value = arith.getIntValue(attr) orelse return null;
    return .{ .int = value };
}

fn testBuildScalar(ir_ctx: *ir.Context, value: Scalar) anyerror!ir.Attribute {
    return switch (value) {
        .int => |int_value| arith.getIntAttr(ir_ctx, int_value),
        else => error.UnsupportedScalar,
    };
}

fn patternZeroRules(rule_set: *RewriteSet) anyerror!void {
    rule_set.setConstantModel(.{
        .op_name = "arith.constant",
        .classify = testClassifyType,
        .read = testReadScalar,
        .build = testBuildScalar,
    });
    try rule_set.addPattern(.{
        .name = "test-binary-zero-pattern",
        .benefit = 10,
        .classes = &.{.integer},
        .lhs = .{
            .name = "arith.add",
            .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } },
        },
        .rhs = .{ .variable = 0 },
    });
}

const PatternTestPass = EGraphPass(.{
    .name = "choir-egraph-pattern-test",
    .description = "test egraph pattern rule pass",
    .populate_rules = patternZeroRules,
    .options = .{ .candidate = testCandidate },
});

test "egraph pattern rules rewrite expressions as data" {
    const test_dialect = test_support.TestDialect;
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.getScalarType(&ctx, .i64);
    const module = try test_dialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    var value = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 7);
    var zero = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 0);
    var add = try arith.AddOp.create(&ctx, loc, zero.getResult(), value.getResult());
    const ret = try test_dialect.ReturnOp.create(&ctx, loc, &.{add.getResult()});

    try block.addOperation(value.op);
    try block.addOperation(zero.op);
    try block.addOperation(add.op);
    try block.addOperation(ret.op);

    var pm = pass_mod.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(PatternTestPass.create());
    try testing.expectEqual(pass_mod.PassResult.success, pm.run(module.op, &ctx));

    try testing.expect(ret.op.getOperand(0).? == value.getResult());
}

fn constantAddRules(rule_set: *RewriteSet) anyerror!void {
    rule_set.setConstantModel(.{
        .op_name = "arith.constant",
        .classify = testClassifyType,
        .read = testReadScalar,
        .build = testBuildScalar,
    });
    try rule_set.addPattern(.{
        .name = "test-constant-add",
        .benefit = 10,
        .classes = &.{.integer},
        .lhs = .{
            .name = "arith.add",
            .operands = &.{ .{ .constant = .{ .int = 7 } }, .{ .constant = .{ .int = 7 } } },
        },
        .rhs = .{ .constant = .{ .int = 14 } },
    });
}

const ConstantAddTestPass = EGraphPass(.{
    .name = "choir-egraph-self-cancel-test",
    .description = "test egraph constant materialization pass",
    .populate_rules = constantAddRules,
    .options = .{ .candidate = testCandidate },
});

test "egraph extraction materializes constants discovered by rules" {
    const test_dialect = test_support.TestDialect;
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.getScalarType(&ctx, .i64);
    const module = try test_dialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    var value = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 7);
    var diff = try arith.AddOp.create(&ctx, loc, value.getResult(), value.getResult());
    const ret = try test_dialect.ReturnOp.create(&ctx, loc, &.{diff.getResult()});

    try block.addOperation(value.op);
    try block.addOperation(diff.op);
    try block.addOperation(ret.op);

    var pm = pass_mod.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(ConstantAddTestPass.create());
    try testing.expectEqual(pass_mod.PassResult.success, pm.run(module.op, &ctx));

    const replacement = ret.op.getOperand(0).?;
    try testing.expect(replacement != diff.getResult());
    const def_any = replacement.getDefiningOp() orelse return error.TestExpectedResult;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    try testing.expectEqualStrings("arith.constant", def_op.name.name);
    const constant = arith.ConstantOp{ .op = def_op };
    try testing.expectEqual(@as(?i64, 14), constant.getIntValue());
    try ir.verifyOperation(module.op, ir.verify.default_options);
}

fn reductionRules(rule_set: *RewriteSet) anyerror!void {
    rule_set.setConstantModel(.{
        .op_name = "arith.constant",
        .classify = testClassifyType,
        .read = testReadScalar,
        .build = testBuildScalar,
    });
    rule_set.setCostModel(.{
        .overrides = &.{.{ .name = "test.identity", .cost = 1 }},
    });
    try rule_set.addPattern(.{
        .name = "test-add-zero-to-identity",
        .benefit = 10,
        .classes = &.{.integer},
        .lhs = .{
            .name = "arith.add",
            .operands = &.{ .{ .variable = 0 }, .{ .constant = .{ .int = 0 } } },
        },
        .rhs = .{ .operation = .{ .name = "test.identity", .operands = &.{.{ .variable = 0 }} } },
    });
}

const ReductionTestPass = EGraphPass(.{
    .name = "choir-egraph-reduction-test",
    .description = "test egraph operation materialization pass",
    .populate_rules = reductionRules,
    .options = .{ .candidate = testCandidate },
});

test "egraph extraction rejects unqualified cheaper rule products" {
    const test_dialect = test_support.TestDialect;
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.getScalarType(&ctx, .i64);
    const module = try test_dialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    var value = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 7);
    var two = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 0);
    var double = try arith.AddOp.create(&ctx, loc, value.getResult(), two.getResult());
    const ret = try test_dialect.ReturnOp.create(&ctx, loc, &.{double.getResult()});

    try block.addOperation(value.op);
    try block.addOperation(two.op);
    try block.addOperation(double.op);
    try block.addOperation(ret.op);

    var pm = pass_mod.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(ReductionTestPass.create());
    try testing.expectEqual(pass_mod.PassResult.success, pm.run(module.op, &ctx));

    const replacement = ret.op.getOperand(0).?;
    try testing.expect(replacement == double.getResult());
    const def_any = replacement.getDefiningOp() orelse return error.TestExpectedResult;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    try testing.expectEqualStrings("arith.add", def_op.name.name);
    try testing.expect(def_op.getOperand(0).? == value.getResult());
    try ir.verifyOperation(module.op, ir.verify.default_options);
}

test "egraph rewrite budget stops saturation without failing the pass" {
    const test_dialect = test_support.TestDialect;
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.getScalarType(&ctx, .i64);
    const module = try test_dialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    var seven = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 7);
    var eleven = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 11);
    var zero = try arith.ConstantOp.createInt(&ctx, loc, i64_type, 0);
    var add1 = try arith.AddOp.create(&ctx, loc, seven.getResult(), zero.getResult());
    var add2 = try arith.AddOp.create(&ctx, loc, eleven.getResult(), zero.getResult());
    const ret = try test_dialect.ReturnOp.create(&ctx, loc, &.{ add1.getResult(), add2.getResult() });

    try block.addOperation(seven.op);
    try block.addOperation(eleven.op);
    try block.addOperation(zero.op);
    try block.addOperation(add1.op);
    try block.addOperation(add2.op);
    try block.addOperation(ret.op);

    var pm = pass_mod.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(BudgetTestPass.create());
    try testing.expectEqual(pass_mod.PassResult.success, pm.run(module.op, &ctx));

    try testing.expect(ret.op.getOperand(0).? == seven.getResult());
    try testing.expect(ret.op.getOperand(1).? == add2.getResult());
}

const std = @import("std");
const alloc_phase = @import("alloc_phase");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const test_dialect = @import("../../dialects/fixture/root.zig");
const passes = @import("../root.zig");
const pass_mod = @import("../pass/root.zig");
const instrumentation = passes.instrumentation;
const cse = @import("root.zig");

const common_subexpression_elimination_pass_name =
    cse.common_subexpression_elimination_pass_name;
const createCommonSubexpressionEliminationPass =
    cse.createCommonSubexpressionEliminationPass;
const run = cse.run;
const PassResult = pass_mod.PassResult;

const testing = std.testing;
const arith = dialects.ArithDialect;

fn buildTestContext(allocator: std.mem.Allocator) !ir.Context {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    errdefer ctx.deinit(allocator);
    try test_dialect.registerTestDialect(&ctx);
    try ir.dialects.loadDialectSpec(&ctx, dialects.arith.spec);
    return ctx;
}

fn runCsePass(allocator: std.mem.Allocator, module: *ir.Operation, ctx: *ir.Context) !pass_mod.PassManager {
    var pm = pass_mod.PassManager.init(allocator);
    errdefer pm.deinit();
    try pm.addPass(createCommonSubexpressionEliminationPass());
    try testing.expectEqual(PassResult.success, pm.run(module, ctx));
    return pm;
}

fn createBinary(
    ctx: *ir.Context,
    block: *ir.Block,
    lhs: *ir.Value,
    rhs: *ir.Value,
) !arith.AddOp {
    const op = try arith.AddOp.create(ctx, ir.Location.getUnknown(), lhs, rhs);
    try block.addOperation(op.op);
    return op;
}

fn createBranch(ctx: *ir.Context, block: *ir.Block, successors: []const *ir.Block) !*ir.Operation {
    var builder = ir.OperationBuilder.init(ctx);
    var state = ir.Operation.State.init("test.br", ir.Location.getUnknown());
    state.addSuccessors(successors);
    const op = try builder.create(state);
    try block.addOperation(op);
    return op;
}

fn createReturn(ctx: *ir.Context, block: *ir.Block, operands: []const *ir.Value) !test_dialect.TestDialect.ReturnOp {
    const op = try test_dialect.TestDialect.ReturnOp.create(ctx, ir.Location.getUnknown(), operands);
    try block.addOperation(op.op);
    return op;
}

fn registerEffectfulValueOp(ctx: *ir.Context) !void {
    try ctx.registerOperationInterface(
        "test.effectful_value",
        ir.interfaces.EffectOpInterface.entryFor(.{}),
    );
}

fn createEffectfulValue(
    ctx: *ir.Context,
    block: *ir.Block,
    lhs: *ir.Value,
    rhs: *ir.Value,
) !*ir.Operation {
    var builder = ir.OperationBuilder.init(ctx);
    var state = ir.Operation.State.init("test.effectful_value", ir.Location.getUnknown());
    state.addOperands(&.{ lhs, rhs });
    state.addTypes(&.{lhs.type});
    const op = try builder.create(state);
    try block.addOperation(op);
    return op;
}

fn createResultOp(ctx: *ir.Context, block: *ir.Block, name: []const u8, result_type: ir.Type) !*ir.Operation {
    var builder = ir.OperationBuilder.init(ctx);
    var state = ir.Operation.State.init(name, ir.Location.getUnknown());
    state.addTypes(&.{result_type});
    const op = try builder.create(state);
    if (std.mem.eql(u8, name, "arith.constant")) try op.setAttr(
        "value",
        try arith.getIntAttr(ctx, 42),
    );
    try block.addOperation(op);
    return op;
}

fn cseAttributeValueIncludesKeyAttr(_: *const anyopaque, name: []const u8, _: ir.Attribute) bool {
    return !std.mem.eql(u8, name, "test.debug_span");
}

fn cseKeyPolicyIncludesKeyAttr(_: *const anyopaque, _: []const u8, _: ir.Attribute) bool {
    return true;
}

fn cseKeyPolicyCommutesOperands(_: *const anyopaque) bool {
    return true;
}

fn registerCseAttributeValueOp(ctx: *ir.Context) !void {
    _ = try ctx.registerOperation("arith.constant", .{});
    try ctx.registerOperationInterface(
        "arith.constant",
        ir.interfaces.CseOpInterface.entryFor(cseAttributeValueIncludesKeyAttr),
    );
}

fn registerCseKeyPolicyBinaryOp(ctx: *ir.Context) !void {
    ctx.lookupOperation("arith.add").?.traits.is_commutative = false;
    try ctx.registerOperationInterface(
        "arith.add",
        ir.interfaces.CseOpInterface.keyPolicyEntryFor(
            cseKeyPolicyIncludesKeyAttr,
            cseKeyPolicyCommutesOperands,
        ),
    );
}

fn createCseAttributeValue(
    ctx: *ir.Context,
    block: *ir.Block,
    result_type: ir.Type,
    debug_span: i64,
) !*ir.Operation {
    var builder = ir.OperationBuilder.init(ctx);
    var state = ir.Operation.State.init("arith.constant", ir.Location.getUnknown());
    state.addTypes(&.{result_type});
    const op = try builder.create(state);
    try op.setAttr("value", try arith.getIntAttr(ctx, 42));
    try op.setAttr("test.debug_span", try ctx.getI64Attr(debug_span));
    try block.addOperation(op);
    return op;
}

fn createCseKeyPolicyBinary(
    ctx: *ir.Context,
    block: *ir.Block,
    lhs: *ir.Value,
    rhs: *ir.Value,
) !*ir.Operation {
    var builder = ir.OperationBuilder.init(ctx);
    var state = ir.Operation.State.init("arith.add", ir.Location.getUnknown());
    state.addOperands(&.{ lhs, rhs });
    state.addTypes(&.{lhs.type});
    const op = try builder.create(state);
    try block.addOperation(op);
    return op;
}

test "choir-cse eliminates qualified wrapping-add block-local duplicates" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const lhs = try block.addArgument(i32_type, ir.Location.getUnknown());
    const rhs = try block.addArgument(i32_type, ir.Location.getUnknown());

    const first = try createBinary(&ctx, block, lhs, rhs);
    const second = try createBinary(&ctx, block, lhs, rhs);
    const ret = try createReturn(&ctx, block, &.{second.getResult()});

    var statistics = instrumentation.PassStatisticsInstrumentation.init(allocator);
    defer statistics.deinit();

    var pm = pass_mod.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addInstrumentation(statistics.instrumentation());
    try pm.addPass(createCommonSubexpressionEliminationPass());
    try testing.expectEqual(PassResult.success, pm.run(module.op, &ctx));

    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.op, arith.AddOp.operation_name));
    try testing.expectEqual(first.getResult(), ret.op.getOperand(0).?);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
    try testing.expectEqual(@as(u64, 0), pm.stats.analysis_hits);
    try testing.expectEqual(@as(u64, 0), pm.stats.analysis_misses);
    try testing.expectEqual(@as(u64, 0), pm.stats.analyses_invalidated);
    try testing.expectEqual(@as(u64, 1), statistics.get(common_subexpression_elimination_pass_name, "replacements").?);
}

test "choir-cse allocates only its exact workspace before mutation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Workspace, "cse_steady_no_alloc"),
        );
    }

    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    _ = try ctx.registerOperation("arith.add", .{});

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const lhs = try block.addArgument(i32_type, ir.Location.getUnknown());
    const rhs = try block.addArgument(i32_type, ir.Location.getUnknown());

    var first_state = ir.Operation.State.init("arith.add", ir.Location.getUnknown());
    first_state.addOperands(&.{ lhs, rhs });
    first_state.addTypes(&.{i32_type});
    const first = try ctx.createOperation(first_state);
    try block.addOperation(first);

    var second_state = ir.Operation.State.init("arith.add", ir.Location.getUnknown());
    second_state.addOperands(&.{ lhs, rhs });
    second_state.addTypes(&.{i32_type});
    const second = try ctx.createOperation(second_state);
    try block.addOperation(second);
    const ret = try createReturn(
        &ctx,
        block,
        &.{second.getResult(0).?},
    );

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var analysis_cache = pass_mod.AnalysisCache.init(failing.allocator(), null);
    defer analysis_cache.deinit();
    var pass_ctx = pass_mod.PassContext.init(
        module.op,
        &ctx,
        failing.allocator(),
        &analysis_cache,
    );
    defer pass_ctx.deinit();

    try testing.expectEqual(PassResult.success, run(&pass_ctx));
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            module.op,
            "arith.add",
        ),
    );
    try testing.expectEqual(first.getResult(0).?, ret.op.getOperand(0).?);
}

test "choir-cse isolates nested region candidates while reusing scoped slots" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    _ = try ctx.registerOperation("arith.constant", .{});
    _ = try ctx.registerOperation("test.cse_scope", .{});

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const first = try createResultOp(&ctx, block, "arith.constant", i32_type);

    var scope_state = ir.Operation.State.init("test.cse_scope", ir.Location.getUnknown());
    scope_state.addRegion();
    const scope = try ctx.createOperation(scope_state);
    try block.addOperation(scope);
    const nested_block = try scope.getRegion(0).?.addBlock();
    const nested = try createResultOp(
        &ctx,
        nested_block,
        "arith.constant",
        i32_type,
    );

    const second = try createResultOp(&ctx, block, "arith.constant", i32_type);
    const ret = try createReturn(&ctx, block, &.{second.getResult(0).?});

    var pm = try runCsePass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(
        @as(usize, 2),
        ir.inspection.countOperationsNamed(module.op, "arith.constant"),
    );
    try testing.expectEqual(nested_block, nested.parent_block.?);
    try testing.expectEqual(first.getResult(0).?, ret.op.getOperand(0).?);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "choir-cse lets ops exclude nonsemantic attributes" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try registerCseAttributeValueOp(&ctx);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const first = try createCseAttributeValue(&ctx, block, i32_type, 10);
    const second = try createCseAttributeValue(&ctx, block, i32_type, 20);
    const ret = try createReturn(&ctx, block, &.{second.getResult(0).?});

    var pm = try runCsePass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(module.op, "arith.constant"),
    );
    try testing.expectEqual(first.getResult(0).?, ret.op.getOperand(0).?);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "choir-cse keeps different interned attribute values distinct" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    _ = try ctx.registerOperation("arith.constant", .{});

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);

    const first = try createResultOp(&ctx, block, "arith.constant", i32_type);
    try first.setAttr("test.value", try ctx.getI64Attr(1));
    const second = try createResultOp(&ctx, block, "arith.constant", i32_type);
    try second.setAttr("test.value", try ctx.getI64Attr(2));
    const ret = try createReturn(&ctx, block, &.{second.getResult(0).?});

    var pm = try runCsePass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(
        @as(usize, 2),
        ir.inspection.countOperationsNamed(module.op, "arith.constant"),
    );
    try testing.expectEqual(second.getResult(0).?, ret.op.getOperand(0).?);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "choir-cse lets op key policy commute operands" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try registerCseKeyPolicyBinaryOp(&ctx);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const lhs = try block.addArgument(i32_type, ir.Location.getUnknown());
    const rhs = try block.addArgument(i32_type, ir.Location.getUnknown());

    const first = try createCseKeyPolicyBinary(&ctx, block, lhs, rhs);
    const second = try createCseKeyPolicyBinary(&ctx, block, rhs, lhs);
    const ret = try createReturn(&ctx, block, &.{second.getResult(0).?});

    var pm = try runCsePass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(module.op, "arith.add"),
    );
    try testing.expectEqual(first.getResult(0).?, ret.op.getOperand(0).?);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "choir-cse keys operands after earlier replacements" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    _ = try ctx.registerOperation("arith.constant", .{});

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const seed = try block.addArgument(i32_type, ir.Location.getUnknown());

    const first_leaf = try createResultOp(&ctx, block, "arith.constant", i32_type);
    const first = try createBinary(&ctx, block, seed, first_leaf.getResult(0).?);
    const second_leaf = try createResultOp(&ctx, block, "arith.constant", i32_type);
    const second = try createBinary(&ctx, block, seed, second_leaf.getResult(0).?);
    const ret = try createReturn(&ctx, block, &.{second.getResult()});

    var pm = try runCsePass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(module.op, "arith.constant"),
    );
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.op, arith.AddOp.operation_name));
    try testing.expectEqual(first.getResult(), ret.op.getOperand(0).?);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "choir-cse uses commutative traits for arith add" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, dialects.arith.spec);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const lhs = try block.addArgument(i32_type, ir.Location.getUnknown());
    const rhs = try block.addArgument(i32_type, ir.Location.getUnknown());

    const first = try arith.AddOp.create(&ctx, ir.Location.getUnknown(), lhs, rhs);
    try block.addOperation(first.op);
    const second = try arith.AddOp.create(&ctx, ir.Location.getUnknown(), rhs, lhs);
    try block.addOperation(second.op);
    const ret = try createReturn(&ctx, block, &.{second.getResult()});

    var pm = try runCsePass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.op, arith.AddOp.operation_name));
    try testing.expectEqual(first.getResult(), ret.op.getOperand(0).?);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "choir-cse eliminates duplicates dominated by an earlier block" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const region = module.getBody();
    const entry = module.getBodyBlock();
    const merge = try region.addBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const lhs = try entry.addArgument(i32_type, ir.Location.getUnknown());
    const rhs = try entry.addArgument(i32_type, ir.Location.getUnknown());

    const first = try createBinary(&ctx, entry, lhs, rhs);
    _ = try createBranch(&ctx, entry, &.{merge});
    const second = try createBinary(&ctx, merge, lhs, rhs);
    const ret = try createReturn(&ctx, merge, &.{second.getResult()});

    var pm = try runCsePass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            module.op,
            arith.AddOp.operation_name,
        ),
    );
    try testing.expectEqual(first.getResult(), ret.op.getOperand(0).?);
    try testing.expectEqual(@as(u64, 0), pm.stats.analysis_hits);
    try testing.expectEqual(@as(u64, 2), pm.stats.analysis_misses);
}

test "choir-cse skips dominance when candidates occupy one of several blocks" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const region = module.getBody();
    const entry = module.getBodyBlock();
    const merge = try region.addBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const lhs = try entry.addArgument(i32_type, ir.Location.getUnknown());
    const rhs = try entry.addArgument(i32_type, ir.Location.getUnknown());

    const first = try createBinary(&ctx, entry, lhs, rhs);
    const second = try createBinary(&ctx, entry, lhs, rhs);
    _ = try createBranch(&ctx, entry, &.{merge});
    const ret = try createReturn(&ctx, merge, &.{second.getResult()});

    var pm = try runCsePass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            module.op,
            arith.AddOp.operation_name,
        ),
    );
    try testing.expectEqual(first.getResult(), ret.op.getOperand(0).?);
    try testing.expectEqual(@as(u64, 0), pm.stats.analysis_hits);
    try testing.expectEqual(@as(u64, 0), pm.stats.analysis_misses);
}

test "choir-cse keeps equal branch values when neither dominates the other" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const region = module.getBody();
    const entry = module.getBodyBlock();
    const then_block = try region.addBlock();
    const else_block = try region.addBlock();
    const merge = try region.addBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const lhs = try entry.addArgument(i32_type, ir.Location.getUnknown());
    const rhs = try entry.addArgument(i32_type, ir.Location.getUnknown());

    _ = try createBranch(&ctx, entry, &.{ then_block, else_block });
    _ = try createBinary(&ctx, then_block, lhs, rhs);
    _ = try createBranch(&ctx, then_block, &.{merge});
    _ = try createBinary(&ctx, else_block, lhs, rhs);
    _ = try createBranch(&ctx, else_block, &.{merge});
    _ = try createReturn(&ctx, merge, &.{});

    var pm = try runCsePass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(
        @as(usize, 2),
        ir.inspection.countOperationsNamed(
            module.op,
            arith.AddOp.operation_name,
        ),
    );
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
    try testing.expectEqual(@as(u64, 0), pm.stats.analysis_hits);
    try testing.expectEqual(@as(u64, 2), pm.stats.analysis_misses);
}

test "choir-cse keeps effectful duplicates" {
    const allocator = testing.allocator;

    var ctx = try buildTestContext(allocator);
    defer ctx.deinit(allocator);
    try registerEffectfulValueOp(&ctx);

    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const block = module.getBodyBlock();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const lhs = try block.addArgument(i32_type, ir.Location.getUnknown());
    const rhs = try block.addArgument(i32_type, ir.Location.getUnknown());

    _ = try createEffectfulValue(&ctx, block, lhs, rhs);
    const second = try createEffectfulValue(&ctx, block, lhs, rhs);
    const ret = try createReturn(&ctx, block, &.{second.getResult(0).?});

    var pm = try runCsePass(allocator, module.op, &ctx);
    defer pm.deinit();

    try testing.expectEqual(@as(usize, 2), ir.inspection.countOperationsNamed(module.op, "test.effectful_value"));
    try testing.expectEqual(second.getResult(0).?, ret.op.getOperand(0).?);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

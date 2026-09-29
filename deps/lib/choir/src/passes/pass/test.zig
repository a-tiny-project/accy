const std = @import("std");
const alloc_arena = @import("alloc_arena");
const alloc_observe = @import("alloc_observe");
const sys = @import("sys");
const choir = @import("../../root.zig");
const ir = @import("../../core/root.zig");
const diagnostics = choir.diagnostics;
const passes = @import("../root.zig");
const subject = @import("root.zig");
const instrumentation = passes.instrumentation;

const PassInstrumentor = instrumentation.PassInstrumentor;
const PassInfo = instrumentation.PassInfo;
const TimingInstrumentation = instrumentation.TimingInstrumentation;
const CountingInstrumentation = instrumentation.CountingInstrumentation;
const PassStatisticsInstrumentation = instrumentation.PassStatisticsInstrumentation;
const PassMutationScope = subject.PassMutationScope;
const dialectDependencies = subject.dialectDependencies;
const Pass = subject.Pass;
const analysisId = subject.analysisId;
const AnalysisDescriptor = subject.AnalysisDescriptor;
const Analysis = subject.Analysis;
const PassManagerStats = subject.PassManagerStats;
const PassFailureKind = subject.PassFailureKind;
const PreservedAnalyses = subject.PreservedAnalyses;
const AnalysisCache = subject.AnalysisCache;
const PassContext = subject.PassContext;
const PassResult = subject.PassResult;
const PipelineEntry = subject.PipelineEntry;
const OpPassManagerTargetKind = subject.OpPassManagerTargetKind;
const OpPassManager = subject.OpPassManager;
const PassManager = subject.PassManager;
const OperationPass = subject.OperationPass;

test {
    std.testing.refAllDecls(subject);
}

fn test_pass_success(_: *PassContext) PassResult {
    return .success;
}

fn test_pass_failure(_: *PassContext) PassResult {
    return .failure;
}

test "IR context census counts each PassManager pass run once" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);
    const module_op = try test_dialect.TestDialect.ModuleOp.create(
        &ctx,
        ir.Location.getUnknown(),
    );

    var normal = PassManager.init(allocator);
    defer normal.deinit();
    try normal.addPass(.{
        .name = "context-census-success",
        .description = "",
        .run_fn = test_pass_success,
    });
    try testing.expectEqual(PassResult.success, normal.run(module_op.op, &ctx));
    try testing.expectEqual(@as(u64, 1), ctx.passRunCount());
    try testing.expectEqual(
        PassResult.success,
        normal.runWithOptions(module_op.op, &ctx, .{}),
    );
    try testing.expectEqual(@as(u64, 2), ctx.passRunCount());

    var failing = PassManager.init(allocator);
    defer failing.deinit();
    try failing.addPass(.{
        .name = "context-census-failure",
        .description = "",
        .run_fn = test_pass_failure,
    });
    try testing.expectEqual(PassResult.failure, failing.run(module_op.op, &ctx));
    try testing.expectEqual(@as(u64, 3), ctx.passRunCount());

    var fixed = PassManager.init(allocator);
    defer fixed.deinit();
    try fixed.addPass(.{
        .name = "context-census-fixed-point",
        .description = "",
        .run_fn = test_pass_success,
    });
    const fixed_result = fixed.runToFixedPoint(module_op.op, &ctx, 8);
    try testing.expectEqual(PassResult.success, fixed_result.result);
    try testing.expectEqual(@as(usize, 1), fixed_result.iterations);
    try testing.expectEqual(@as(u64, 4), ctx.passRunCount());
}

const OperationPassTestTargetOp = struct {
    op: *ir.Operation,
    pub const operation_name = ir.dialects.operationName("test", "target_op");
};

const OperationPassCounter = struct {
    var count: usize = 0;

    fn run_on_op(_: *OperationPassTestTargetOp, _: *PassContext) PassResult {
        count += 1;
        return .success;
    }
};

const OperationPassTestFailOp = struct {
    op: *ir.Operation,
    pub const operation_name = ir.dialects.operationName("test", "fail_op");
};

const OperationPassFailCounter = struct {
    var count: usize = 0;

    fn run_on_op(_: *OperationPassTestFailOp, _: *PassContext) PassResult {
        count += 1;
        return .failure;
    }
};

test "OperationPass walks and matches operations" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const module_block = module_op.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    const target_name = ir.dialects.operationName("test", "target_op");
    const target1_state = ir.Operation.State.init(target_name, ir.Location.getUnknown());
    const target1_op = try builder.create(target1_state);
    try module_block.addOperation(target1_op);

    const func_op = try test_dialect.TestDialect.FuncOp.create(&ctx, ir.Location.getUnknown(), "test_func", &.{});
    try module_block.addOperation(func_op.op);

    const func_block = func_op.getEntryBlock();

    const target2_state = ir.Operation.State.init(target_name, ir.Location.getUnknown());
    const target2_op = try builder.create(target2_state);
    try func_block.addOperation(target2_op);

    const other_state = ir.Operation.State.init("test.other_op", ir.Location.getUnknown());
    const other_op = try builder.create(other_state);
    try func_block.addOperation(other_op);

    OperationPassCounter.count = 0;

    const TestPass = OperationPass(OperationPassTestTargetOp, OperationPassCounter.run_on_op);
    const pass = TestPass.init("test-pass", "Test pass for counting target ops");

    var analysis_cache = AnalysisCache.init(allocator, null);
    defer analysis_cache.deinit();

    var pass_ctx = PassContext.init(module_op.op, &ctx, allocator, &analysis_cache);
    defer pass_ctx.deinit();
    const result = pass.base.run(&pass_ctx);

    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 2), OperationPassCounter.count);
}

test "OperationPass stops on failure" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const module_block = module_op.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    const target_name = ir.dialects.operationName("test", "fail_op");
    const target1_state = ir.Operation.State.init(target_name, ir.Location.getUnknown());
    const target1_op = try builder.create(target1_state);
    try module_block.addOperation(target1_op);

    const target2_state = ir.Operation.State.init(target_name, ir.Location.getUnknown());
    const target2_op = try builder.create(target2_state);
    try module_block.addOperation(target2_op);

    OperationPassFailCounter.count = 0;

    const FailPass = OperationPass(OperationPassTestFailOp, OperationPassFailCounter.run_on_op);
    const pass = FailPass.init("fail-pass", "Pass that always fails");

    var analysis_cache = AnalysisCache.init(allocator, null);
    defer analysis_cache.deinit();

    var pass_ctx = PassContext.init(module_op.op, &ctx, allocator, &analysis_cache);
    defer pass_ctx.deinit();
    const result = pass.base.run(&pass_ctx);

    try testing.expectEqual(PassResult.failure, result);
    try testing.expectEqual(@as(usize, 1), OperationPassFailCounter.count);
}

fn preserveCompileTimeTestAnalysisSet(preserved: *PreservedAnalyses) void {
    preserved.preserveAnalysisSet(&.{
        analysisId("analysis.test.static.a"),
        analysisId("analysis.test.static.c"),
    });
}

test "PreservedAnalyses borrows compile-time analysis sets" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");
    const desc_a = AnalysisDescriptor{
        .id = analysisId("analysis.test.static.a"),
        .name = "analysis.test.static.a",
    };
    const desc_b = AnalysisDescriptor{
        .id = analysisId("analysis.test.static.b"),
        .name = "analysis.test.static.b",
    };
    const desc_c = AnalysisDescriptor{
        .id = analysisId("analysis.test.static.c"),
        .name = "analysis.test.static.c",
    };

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const module_op = try test_dialect.TestDialect.ModuleOp.create(
        &ctx,
        ir.Location.getUnknown(),
    );

    var stats: PassManagerStats = .{};
    var analysis_cache = AnalysisCache.init(allocator, &stats);
    defer analysis_cache.deinit();
    var pass_ctx = PassContext.init(
        module_op.op,
        &ctx,
        allocator,
        &analysis_cache,
    );
    defer pass_ctx.deinit();

    analysis_counter = 0;
    _ = try pass_ctx.getAnalysis(module_op.op, &desc_a, computeCounter, cleanupCounter);
    _ = try pass_ctx.getAnalysis(module_op.op, &desc_b, computeCounter, cleanupCounter);
    _ = try pass_ctx.getAnalysis(module_op.op, &desc_c, computeCounter, cleanupCounter);

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var preserved = PreservedAnalyses.init(failing.allocator());
    defer preserved.deinit();

    preserveCompileTimeTestAnalysisSet(&preserved);

    analysis_cache.invalidate(&preserved);
    const a = try pass_ctx.getAnalysis(module_op.op, &desc_a, computeCounter, cleanupCounter);
    const b = try pass_ctx.getAnalysis(module_op.op, &desc_b, computeCounter, cleanupCounter);
    const c = try pass_ctx.getAnalysis(module_op.op, &desc_c, computeCounter, cleanupCounter);
    try testing.expectEqual(@as(u32, 1), @as(*u32, @ptrCast(@alignCast(a))).*);
    try testing.expectEqual(@as(u32, 4), @as(*u32, @ptrCast(@alignCast(b))).*);
    try testing.expectEqual(@as(u32, 3), @as(*u32, @ptrCast(@alignCast(c))).*);
    try testing.expectEqual(@as(u64, 1), stats.analyses_invalidated);
    try preserved.preserveAnalysis(desc_a.id);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expectError(error.OutOfMemory, preserved.preserveAnalysis(desc_b.id));
}

test "AnalysisCache invalidates based on preserved interfaces" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var stats: PassManagerStats = .{};
    var analysis_cache = AnalysisCache.init(allocator, &stats);
    defer analysis_cache.deinit();

    var pass_ctx = PassContext.init(module_op.op, &ctx, allocator, &analysis_cache);
    defer pass_ctx.deinit();

    const desc_a = AnalysisDescriptor{
        .id = analysisId("analysis.test.a"),
        .name = "analysis.test.a",
    };
    const desc_b = AnalysisDescriptor{
        .id = analysisId("analysis.test.b"),
        .name = "analysis.test.b",
        .required_interfaces = &.{ir.interfaces.EffectOpInterface.id},
    };
    const desc_c = AnalysisDescriptor{
        .id = analysisId("analysis.test.c"),
        .name = "analysis.test.c",
    };

    analysis_counter = 0;
    const a_ptr1 = try pass_ctx.getAnalysis(module_op.op, &desc_a, computeCounter, cleanupCounter);
    const b_ptr1 = try pass_ctx.getAnalysis(module_op.op, &desc_b, computeCounter, cleanupCounter);
    const c_ptr1 = try pass_ctx.getAnalysis(module_op.op, &desc_c, computeCounter, cleanupCounter);

    try testing.expectEqual(@as(u32, 1), @as(*u32, @ptrCast(@alignCast(a_ptr1))).*);
    try testing.expectEqual(@as(u32, 2), @as(*u32, @ptrCast(@alignCast(b_ptr1))).*);
    try testing.expectEqual(@as(u32, 3), @as(*u32, @ptrCast(@alignCast(c_ptr1))).*);

    var preserved = PreservedAnalyses.init(allocator);
    defer preserved.deinit();
    try preserved.preserveInterface(ir.interfaces.EffectOpInterface.id);

    analysis_cache.invalidate(&preserved);

    const a_ptr2 = try pass_ctx.getAnalysis(module_op.op, &desc_a, computeCounter, cleanupCounter);
    const b_ptr2 = try pass_ctx.getAnalysis(module_op.op, &desc_b, computeCounter, cleanupCounter);
    const c_ptr2 = try pass_ctx.getAnalysis(module_op.op, &desc_c, computeCounter, cleanupCounter);

    try testing.expectEqual(@as(u32, 4), @as(*u32, @ptrCast(@alignCast(a_ptr2))).*);
    try testing.expectEqual(@as(u32, 2), @as(*u32, @ptrCast(@alignCast(b_ptr2))).*);
    try testing.expectEqual(@as(u32, 5), @as(*u32, @ptrCast(@alignCast(c_ptr2))).*);
    try testing.expectEqual(@as(u64, 2), stats.analyses_invalidated);
}

test "PassContext instruments analysis computation misses" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var stats: PassManagerStats = .{};
    var analysis_cache = AnalysisCache.init(allocator, &stats);
    defer analysis_cache.deinit();

    var counter = CountingInstrumentation{};
    var timing = TimingInstrumentation.init(allocator);
    defer timing.deinit();

    var instrumentor = PassInstrumentor.init(allocator);
    defer instrumentor.deinit();
    try instrumentor.addInstrumentation(counter.instrumentation());
    try instrumentor.addInstrumentation(timing.instrumentation());

    var pass_ctx = PassContext.initWithInstrumentor(
        module_op.op,
        &ctx,
        allocator,
        &analysis_cache,
        &instrumentor,
    );
    defer pass_ctx.deinit();

    const desc = AnalysisDescriptor{
        .id = analysisId("analysis.test.instrumented"),
        .name = "analysis.test.instrumented",
    };

    analysis_counter = 0;
    const first = try pass_ctx.getAnalysis(module_op.op, &desc, computeCounter, cleanupCounter);
    const second = try pass_ctx.getAnalysis(module_op.op, &desc, computeCounter, cleanupCounter);

    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 1), counter.analysis_count);
    try testing.expectEqual(@as(u64, 1), stats.analysis_misses);
    try testing.expectEqual(@as(u64, 1), stats.analysis_hits);
    try testing.expectEqual(@as(u64, 1), timing.getAnalysisCount(desc.name).?);
    try testing.expect(timing.getAnalysisTime(desc.name) != null);
}

test "Analysis wraps typed compute and cleanup callbacks" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var stats: PassManagerStats = .{};
    typed_analysis_counter = 0;
    typed_analysis_cleanup_count = 0;

    {
        var analysis_cache = AnalysisCache.init(allocator, &stats);
        defer analysis_cache.deinit();

        var pass_ctx = PassContext.init(module_op.op, &ctx, allocator, &analysis_cache);
        defer pass_ctx.deinit();

        try testing.expectEqual(analysisId("analysis.test.typed"), TypedCounterAnalysis.id);
        try testing.expect(TypedCounterAnalysis.value_type == u32);
        try testing.expectEqualStrings("analysis.test.typed", TypedCounterAnalysis.descriptor.name);

        const first = try TypedCounterAnalysis.get(&pass_ctx, module_op.op);
        const second = try TypedCounterAnalysis.get(&pass_ctx, module_op.op);

        try testing.expectEqual(first, second);
        try testing.expectEqual(@as(u32, 1), first.*);
        try testing.expectEqual(@as(u64, 1), stats.analysis_misses);
        try testing.expectEqual(@as(u64, 1), stats.analysis_hits);

        var preserved = PreservedAnalyses.init(allocator);
        defer preserved.deinit();
        analysis_cache.invalidate(&preserved);

        try testing.expectEqual(@as(u32, 1), typed_analysis_cleanup_count);

        const third = try TypedCounterAnalysis.get(&pass_ctx, module_op.op);
        try testing.expectEqual(@as(u32, 2), third.*);

        try TypedCounterAnalysis.preserve(&pass_ctx);
        analysis_cache.invalidate(&pass_ctx.preserved);
        try testing.expectEqual(@as(u32, 1), typed_analysis_cleanup_count);
        try testing.expectEqual(third, try TypedCounterAnalysis.get(&pass_ctx, module_op.op));
    }

    try testing.expectEqual(@as(u32, 2), typed_analysis_cleanup_count);
}

test "AnalysisCache cleans computed values after insertion failure" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");
    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var stats: PassManagerStats = .{};
    typed_analysis_counter = 0;
    typed_analysis_cleanup_count = 0;
    {
        var cache = AnalysisCache.init(failing.allocator(), &stats);
        defer cache.deinit();
        var pass_ctx = PassContext.init(module.op, &ctx, failing.allocator(), &cache);
        defer pass_ctx.deinit();

        try testing.expectError(error.OutOfMemory, TypedCounterAnalysis.get(&pass_ctx, module.op));
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqual(@as(u32, 1), typed_analysis_counter);
        try testing.expectEqual(@as(u32, 1), typed_analysis_cleanup_count);
        try testing.expectEqual(@as(usize, 0), cache.entries.count());
        try testing.expectEqual(@as(u64, 0), stats.analysis_misses);

        failing.fail_index = std.math.maxInt(usize);
        const fresh = try TypedCounterAnalysis.get(&pass_ctx, module.op);
        try testing.expectEqual(@as(u32, 2), fresh.*);
        try testing.expectEqual(@as(u32, 2), typed_analysis_counter);
        try testing.expectEqual(@as(u32, 1), typed_analysis_cleanup_count);
        try testing.expectEqual(@as(usize, 1), cache.entries.count());
        try testing.expectEqual(@as(u64, 1), stats.analysis_misses);
        try testing.expectEqual(fresh, try TypedCounterAnalysis.get(&pass_ctx, module.op));
        try testing.expectEqual(@as(u32, 2), typed_analysis_counter);
        try testing.expectEqual(@as(u64, 1), stats.analysis_hits);
    }
    try testing.expectEqual(@as(u32, 2), typed_analysis_cleanup_count);
}

const OperationVersionAnalysis = Analysis(
    i64,
    "analysis.test.operation-version",
    &.{},
    computeOperationVersion,
    cleanupOperationVersion,
    null,
);

fn computeOperationVersion(ctx: *PassContext, op: *ir.Operation) anyerror!*i64 {
    const version = op.getAttr("analysis_version").?.cast(ir.Attribute.IntegerAttr).?.value;
    const value = try ctx.allocator.create(i64);
    value.* = version;
    return value;
}

fn cleanupOperationVersion(value: *i64, allocator: std.mem.Allocator) void {
    allocator.destroy(value);
}

const MutatingFailurePass = struct {
    fn run(ctx: *PassContext) PassResult {
        const version = ctx.ir_ctx.getI64Attr(2) catch return .failure;
        ctx.op.setAttr("analysis_version", version) catch return .failure;
        ctx.markModified();
        return .failure;
    }

    fn preserving(ctx: *PassContext) PassResult {
        ctx.preserveAllAnalyses();
        return run(ctx);
    }
};

test "PassManager failing mutations honor analysis preservation" {
    try expectFailedMutationCache(false);
    try expectFailedMutationCache(true);
}

fn expectFailedMutationCache(preserve_all: bool) !void {
    const testing = std.testing;
    const allocator = testing.allocator;
    const test_dialect = @import("../../dialects/fixture/root.zig");
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);
    const module = try test_dialect.TestDialect.ModuleOp.create(&ctx, .unknown);
    try module.op.setAttr("analysis_version", try ctx.getI64Attr(1));
    _ = try ctx.getI64Attr(2);
    var stats: PassManagerStats = .{};
    var cache = AnalysisCache.init(allocator, &stats);
    defer cache.deinit();
    var pass_ctx = PassContext.init(module.op, &ctx, allocator, &cache);
    defer pass_ctx.deinit();
    const before = (try OperationVersionAnalysis.get(&pass_ctx, module.op)).*;
    try testing.expectEqual(@as(i64, 1), before);
    var pm = PassManager.init(allocator);
    defer pm.deinit();
    var counter = CountingInstrumentation{};
    try pm.addInstrumentation(counter.instrumentation());
    try pm.addPass(.{
        .name = "mutating-failure",
        .description = "",
        .run_fn = if (preserve_all) MutatingFailurePass.preserving else MutatingFailurePass.run,
    });

    try testing.expectEqual(.failure, pm.runWithAnalysisCache(module.op, &ctx, &cache, .{}));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_failures);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
    try testing.expectEqual(@as(usize, 1), counter.pass_failures);
    const invalidated: u64 = if (preserve_all) 0 else 1;
    try testing.expectEqual(invalidated, pm.stats.analyses_invalidated);
    try testing.expect(cache.stats == &stats);
    const observed = module.op.getAttr("analysis_version").?.cast(ir.Attribute.IntegerAttr).?.value;
    try testing.expectEqual(@as(i64, 2), observed);
    const after = (try OperationVersionAnalysis.get(&pass_ctx, module.op)).*;
    try testing.expectEqual(if (preserve_all) before else observed, after);
    const misses: u64 = if (preserve_all) 1 else 2;
    const hits: u64 = if (preserve_all) 1 else 0;
    try testing.expectEqual(misses, stats.analysis_misses);
    try testing.expectEqual(hits, stats.analysis_hits);
}

var analysis_counter: u32 = 0;

fn computeCounter(ctx: *PassContext, _: *ir.Operation) anyerror!*anyopaque {
    analysis_counter += 1;
    const ptr = try ctx.allocator.create(u32);
    ptr.* = analysis_counter;
    return @ptrCast(ptr);
}

fn cleanupCounter(value: *anyopaque, allocator: std.mem.Allocator) void {
    const ptr: *u32 = @ptrCast(@alignCast(value));
    allocator.destroy(ptr);
}

const TypedCounterAnalysis = Analysis(
    u32,
    "analysis.test.typed",
    &.{},
    computeTypedCounter,
    cleanupTypedCounter,
    null,
);

var typed_analysis_counter: u32 = 0;
var typed_analysis_cleanup_count: u32 = 0;

fn computeTypedCounter(ctx: *PassContext, _: *ir.Operation) anyerror!*u32 {
    typed_analysis_counter += 1;
    const ptr = try ctx.allocator.create(u32);
    ptr.* = typed_analysis_counter;
    return ptr;
}

fn cleanupTypedCounter(value: *u32, allocator: std.mem.Allocator) void {
    typed_analysis_cleanup_count += 1;
    allocator.destroy(value);
}

const CallerCacheAnalysisRunner = struct {
    fn run(pass_ctx: *PassContext) PassResult {
        _ = TypedCounterAnalysis.get(pass_ctx, pass_ctx.op) catch return .failure;
        pass_ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.runWithAnalysisCache leaves caller cache reusable" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    typed_analysis_counter = 0;
    typed_analysis_cleanup_count = 0;

    var cache = AnalysisCache.init(allocator, null);
    defer cache.deinit();

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(.{
        .name = "caller-cache-analysis",
        .description = "",
        .run_fn = CallerCacheAnalysisRunner.run,
        .mutation_scope = .read_only,
    });

    try testing.expectEqual(PassResult.success, pm.runWithAnalysisCache(module_op.op, &ctx, &cache, .{}));
    try testing.expect(cache.stats == null);
    try testing.expectEqual(@as(u64, 1), pm.stats.analysis_misses);
    try testing.expectEqual(@as(u32, 1), typed_analysis_counter);

    var pass_ctx = PassContext.init(module_op.op, &ctx, allocator, &cache);
    defer pass_ctx.deinit();
    const value = try TypedCounterAnalysis.get(&pass_ctx, module_op.op);

    try testing.expectEqual(@as(u32, 1), value.*);
    try testing.expectEqual(@as(u32, 1), typed_analysis_counter);
    try testing.expectEqual(@as(u32, 0), typed_analysis_cleanup_count);
}

fn loadPassDependencyTestDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, .{ .name = "passdep" });
}

fn loadFixedPointDependencyTestDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, .{ .name = "fixeddep" });
}

fn appendInvalidTestConstant(ctx: *PassContext) PassResult {
    const test_dialect = @import("../../dialects/fixture/root.zig");

    const module = test_dialect.TestDialect.ModuleOp{ .op = ctx.op };
    appendInvalidTestConstantToBlock(ctx.ir_ctx, module.getBodyBlock()) catch return .failure;
    ctx.markModified();
    return .success;
}

fn appendInvalidTestConstantToBlock(ctx: *ir.Context, block: *ir.Block) !void {
    const test_dialect = @import("../../dialects/fixture/root.zig");

    const i32_type = try test_dialect.TestDialect.getI32Type(ctx);
    var builder = ir.OperationBuilder.init(ctx);
    var state = ir.Operation.State.init(test_dialect.TestDialect.ConstantOp.operation_name, ir.Location.getUnknown());
    state.addTypes(&.{i32_type});
    const bad_op = try builder.create(state);
    try block.addOperation(bad_op);
}

test "OpPassManager basic nesting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pm = OpPassManager.init(allocator, null);
    defer pm.deinit();

    try testing.expectEqual(@as(?[]const u8, null), pm.target_op_name);
    try testing.expectEqual(OpPassManagerTargetKind.root, pm.target_kind);
    try testing.expectEqual(@as(usize, 0), pm.getNestingDepth());

    const func_pm = try pm.nest("func.func");
    try testing.expectEqualStrings("func.func", func_pm.target_op_name.?);
    try testing.expectEqual(OpPassManagerTargetKind.op, func_pm.target_kind);
    try testing.expectEqual(@as(usize, 1), func_pm.getNestingDepth());
    try testing.expectEqual(&pm, func_pm.parent.?);

    const loop_pm = try func_pm.nest("scf.for");
    try testing.expectEqualStrings("scf.for", loop_pm.target_op_name.?);
    try testing.expectEqual(@as(usize, 2), loop_pm.getNestingDepth());
    try testing.expectEqual(func_pm, loop_pm.parent.?);
}

test "OpPassManager supports op-agnostic nested manager" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pm = OpPassManager.init(allocator, null);
    defer pm.deinit();

    const any_pm = try pm.nestAny();
    try testing.expectEqual(@as(?[]const u8, null), any_pm.target_op_name);
    try testing.expectEqual(OpPassManagerTargetKind.any, any_pm.target_kind);
    try testing.expectEqual(@as(usize, 1), any_pm.getNestingDepth());
    try testing.expectEqual(&pm, any_pm.parent.?);

    try testing.expectEqual(@as(usize, 1), pm.pipeline.items.len);
    try testing.expectEqual(PipelineEntry{ .nested = any_pm }, pm.pipeline.items[0]);
}

test "PassManager.nest creates nested pipeline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const func_pm = try pm.nest("func.func");
    try testing.expectEqualStrings("func.func", func_pm.target_op_name.?);

    try testing.expectEqual(@as(usize, 1), pm.root.pipeline.items.len);
    try testing.expectEqual(PipelineEntry{ .nested = func_pm }, pm.root.pipeline.items[0]);
}

test "PassManager.nestAny creates op-agnostic nested pipeline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const any_pm = try pm.nestAny();
    try testing.expectEqual(OpPassManagerTargetKind.any, any_pm.target_kind);
    try testing.expectEqual(@as(?[]const u8, null), any_pm.target_op_name);

    try testing.expectEqual(@as(usize, 1), pm.root.pipeline.items.len);
    try testing.expectEqual(PipelineEntry{ .nested = any_pm }, pm.root.pipeline.items[0]);
}

const UnregisteredTargetCounter = struct {
    var count: usize = 0;

    fn run(_: *PassContext) PassResult {
        count += 1;
        return .success;
    }
};

test "PassManager rejects unregistered nested pass targets" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const module_block = module_op.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    const state = ir.Operation.State.init("test.unregistered_target", ir.Location.getUnknown());
    const target = try builder.create(state);
    try module_block.addOperation(target);

    UnregisteredTargetCounter.count = 0;

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const nested = try pm.nest("test.unregistered_target");
    try nested.addPass(.{
        .name = "must-not-run",
        .description = "",
        .run_fn = UnregisteredTargetCounter.run,
    });

    try testing.expectEqual(PassResult.failure, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(usize, 0), UnregisteredTargetCounter.count);
}

const NonIsolatedTargetCounter = struct {
    var count: usize = 0;

    fn run(_: *PassContext) PassResult {
        count += 1;
        return .success;
    }
};

test "PassManager rejects non-isolated nested pass targets" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const module_block = module_op.getBodyBlock();

    _ = try ctx.registerOperation("test.non_isolated_target", .{});

    var builder = ir.OperationBuilder.init(&ctx);
    const state = ir.Operation.State.init("test.non_isolated_target", ir.Location.getUnknown());
    const target = try builder.create(state);
    try module_block.addOperation(target);

    NonIsolatedTargetCounter.count = 0;

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const nested = try pm.nest("test.non_isolated_target");
    try nested.addPass(.{
        .name = "must-not-run",
        .description = "",
        .run_fn = NonIsolatedTargetCounter.run,
    });

    try testing.expectEqual(PassResult.failure, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(usize, 0), NonIsolatedTargetCounter.count);
}

const AnyTargetCounter = struct {
    var count: usize = 0;
    var saw_func = false;

    fn run(ctx: *PassContext) PassResult {
        const dialect = @import("../../dialects/fixture/root.zig");
        count += 1;
        if (std.mem.eql(u8, ctx.op.name.name, dialect.TestDialect.FuncOp.operation_name)) {
            saw_func = true;
        }
        return .success;
    }
};

test "PassManager.nestAny runs registered isolated targets and skips non-viable operations" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    _ = try ctx.registerOperation("test.non_isolated_target", .{});

    var builder = ir.OperationBuilder.init(&ctx);
    const unregistered_state = ir.Operation.State.init("test.unregistered_target", loc);
    const unregistered = try builder.create(unregistered_state);
    try module_block.addOperation(unregistered);

    const non_isolated_state = ir.Operation.State.init("test.non_isolated_target", loc);
    const non_isolated = try builder.create(non_isolated_state);
    try module_block.addOperation(non_isolated);

    const func_op = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "any_target", &.{});
    try module_block.addOperation(func_op.op);

    AnyTargetCounter.count = 0;
    AnyTargetCounter.saw_func = false;

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const any_pm = try pm.nestAny();
    try any_pm.addPass(.{
        .name = "any-counter",
        .description = "counts any isolated target",
        .run_fn = AnyTargetCounter.run,
    });

    try testing.expectEqual(PassResult.success, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(usize, 1), AnyTargetCounter.count);
    try testing.expect(AnyTargetCounter.saw_func);
}

test "OpPassManager collects dependent dialects from nested pipelines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    try pm.addPass(.{
        .name = "root-dependent-pass",
        .description = "",
        .run_fn = test_pass_success,
        .dependent_dialects = dialectDependencies(&.{ "firstdep", "shareddep" }),
    });

    const nested = try pm.nest("test.func");
    try nested.addPass(.{
        .name = "nested-dependent-pass",
        .description = "",
        .run_fn = test_pass_success,
        .dependent_dialects = dialectDependencies(&.{ "shareddep", "nesteddep" }),
    });

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    try pm.root.collectDependentDialects(allocator, &names);

    try testing.expectEqual(@as(usize, 3), names.items.len);
    try testing.expectEqualStrings("firstdep", names.items[0]);
    try testing.expectEqualStrings("shareddep", names.items[1]);
    try testing.expectEqualStrings("nesteddep", names.items[2]);
}

const DependentDialectRunner = struct {
    var saw_loaded = false;

    fn run(ctx: *PassContext) PassResult {
        saw_loaded = ctx.ir_ctx.isDialectLoaded("passdep");
        ctx.preserveAllAnalyses();
        return if (saw_loaded) .success else .failure;
    }
};

test "PassManager preloads dependent dialects before running passes" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    try ctx.requireRegistered();
    try ctx.registerDialectLoader("passdep", loadPassDependencyTestDialect);

    DependentDialectRunner.saw_loaded = false;

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(.{
        .name = "dependent-dialect-runner",
        .description = "",
        .run_fn = DependentDialectRunner.run,
        .mutation_scope = .read_only,
        .dependent_dialects = dialectDependencies(&.{"passdep"}),
    });

    try testing.expect(!ctx.isDialectLoaded("passdep"));
    try testing.expectEqual(PassResult.success, pm.run(module_op.op, &ctx));
    try testing.expect(DependentDialectRunner.saw_loaded);
    try testing.expect(ctx.isDialectLoaded("passdep"));
}

const VerifierFailureFollower = struct {
    var runs: usize = 0;

    fn run(_: *PassContext) PassResult {
        runs += 1;
        return .success;
    }
};

test "PassManager verifier stops pipeline after invalid IR" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    VerifierFailureFollower.runs = 0;

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    pm.enableVerifier();
    try pm.addPass(.{
        .name = "append-invalid-constant",
        .description = "",
        .run_fn = appendInvalidTestConstant,
    });
    try pm.addPass(.{
        .name = "must-not-run-after-verifier-failure",
        .description = "",
        .run_fn = VerifierFailureFollower.run,
    });

    try testing.expect(pm.verifierEnabled());
    try testing.expectEqual(PassResult.failure, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.pass_failures);
    try testing.expectEqual(@as(u64, 1), pm.stats.verifier_failures);
    try testing.expectEqual(@as(usize, 0), VerifierFailureFollower.runs);

    const failure = pm.getLastVerifierFailure() orelse return error.TestExpectedVerifierFailure;
    try testing.expectEqualStrings("append-invalid-constant", failure.pass_name);
    try testing.expectEqualStrings(test_dialect.TestDialect.ModuleOp.operation_name, failure.target_op_name);
    try testing.expectEqual(error.MissingRequiredAttribute, failure.err);

    const reproducer = pm.getLastFailureReproducer() orelse return error.TestExpectedReproducer;
    try testing.expectEqualStrings("append-invalid-constant,must-not-run-after-verifier-failure", reproducer.pipeline);
    try testing.expect(reproducer.verifier_enabled);
    try testing.expectEqual(PassFailureKind.verifier, reproducer.failure_kind.?);
    try testing.expectEqualStrings("append-invalid-constant", reproducer.pass_name.?);
    try testing.expectEqual(error.MissingRequiredAttribute, reproducer.verifier_error.?);
}

test "PassManager verifier is opt-in" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(.{
        .name = "append-invalid-constant",
        .description = "",
        .run_fn = appendInvalidTestConstant,
    });

    try testing.expect(!pm.verifierEnabled());
    try testing.expectEqual(PassResult.success, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 1), ctx.passRunCount());
    try testing.expectEqual(@as(u64, 0), pm.stats.verifier_failures);
    try testing.expect(pm.getLastVerifierFailure() == null);
}

const MissingDialectRunner = struct {
    var runs: usize = 0;

    fn run(_: *PassContext) PassResult {
        runs += 1;
        return .success;
    }
};

test "PassManager fails before running passes when dependent dialects are unavailable" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    try ctx.requireRegistered();

    MissingDialectRunner.runs = 0;

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(.{
        .name = "missing-dependent-dialect-runner",
        .description = "",
        .run_fn = MissingDialectRunner.run,
        .dependent_dialects = dialectDependencies(&.{"missingdep"}),
    });

    try testing.expectEqual(PassResult.failure, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(usize, 0), MissingDialectRunner.runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.pass_runs);
}

test "PassManager.runToFixedPoint stops on verifier failure" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    pm.enableVerifier();
    try pm.addPass(.{
        .name = "append-invalid-constant",
        .description = "",
        .run_fn = appendInvalidTestConstant,
    });

    const result = pm.runToFixedPoint(module_op.op, &ctx, 8);
    try testing.expectEqual(PassResult.failure, result.result);
    try testing.expect(!result.changed);
    try testing.expectEqual(@as(usize, 1), result.iterations);
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 1), ctx.passRunCount());
    try testing.expectEqual(@as(u64, 1), pm.stats.verifier_failures);

    const failure = pm.getLastVerifierFailure() orelse return error.TestExpectedVerifierFailure;
    try testing.expectEqualStrings("append-invalid-constant", failure.pass_name);
    try testing.expectEqual(error.MissingRequiredAttribute, failure.err);
}

const FixedPointDependencyRunner = struct {
    var runs: usize = 0;

    fn run(ctx: *PassContext) PassResult {
        if (!ctx.ir_ctx.isDialectLoaded("fixeddep")) return .failure;
        runs += 1;
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.runToFixedPoint preloads dependent dialects before iteration" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    try ctx.requireRegistered();
    try ctx.registerDialectLoader("fixeddep", loadFixedPointDependencyTestDialect);

    FixedPointDependencyRunner.runs = 0;

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(.{
        .name = "fixed-dependent-dialect-runner",
        .description = "",
        .run_fn = FixedPointDependencyRunner.run,
        .dependent_dialects = dialectDependencies(&.{"fixeddep"}),
    });

    const result = pm.runToFixedPoint(module_op.op, &ctx, 8);
    try testing.expectEqual(PassResult.success, result.result);
    try testing.expect(!result.changed);
    try testing.expectEqual(@as(usize, 1), result.iterations);
    try testing.expectEqual(@as(usize, 1), FixedPointDependencyRunner.runs);
    try testing.expect(ctx.isDialectLoaded("fixeddep"));
}

const MutationScopeCapture = struct {
    scope: ?PassMutationScope = null,

    fn before(raw: ?*anyopaque, info: PassInfo) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        self.scope = info.mutation_scope;
    }
};

const MutationScopeRunner = struct {
    fn run(ctx: *PassContext) PassResult {
        ctx.preserveAllAnalyses();
        return .success;
    }
};

const FixedPointRerunRunner = struct {
    var runs: usize = 0;
    var modify_first = false;

    fn run(ctx: *PassContext) PassResult {
        runs += 1;
        if (modify_first and runs == 1) {
            ctx.markModified();
        } else {
            ctx.preserveAllAnalyses();
        }
        return .success;
    }
};

const RerunIntervalRunner = struct {
    var runs: usize = 0;

    fn preserve(ctx: *PassContext) PassResult {
        runs += 1;
        ctx.preserveAllAnalyses();
        return .success;
    }

    fn modify(ctx: *PassContext) PassResult {
        runs += 1;
        ctx.markModified();
        return .success;
    }
};

const StatefulRerunRunner = struct {
    fn run(_: ?*anyopaque, _: *PassContext) PassResult {
        return .success;
    }
};

test "Pass mutation scope reaches instrumentation" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var capture = MutationScopeCapture{};
    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addInstrumentation(.{
        .ctx = &capture,
        .runBeforePass = MutationScopeCapture.before,
    });
    try pm.addPass(.{
        .name = "read-only-test",
        .description = "records pass mutation metadata",
        .run_fn = MutationScopeRunner.run,
        .mutation_scope = .read_only,
    });

    try testing.expectEqual(PassResult.success, pm.run(module_op.op, &ctx));
    try testing.expectEqual(PassMutationScope.read_only, capture.scope.?);
}

test "PassManager skips a fixed-point rerun at the current revision" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    FixedPointRerunRunner.runs = 0;
    FixedPointRerunRunner.modify_first = true;
    RerunIntervalRunner.runs = 0;

    const fixed_point_pass = Pass{
        .name = "fixed-point-rerun",
        .description = "",
        .run_fn = FixedPointRerunRunner.run,
        .rerun_policy = .skip_if_unchanged,
    };

    var counter = CountingInstrumentation{};
    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addInstrumentation(counter.instrumentation());
    try pm.addPass(fixed_point_pass);
    try pm.addPass(.{
        .name = "rerun-interval-preserver",
        .description = "",
        .run_fn = RerunIntervalRunner.preserve,
        .mutation_scope = .read_only,
    });
    try pm.addPass(fixed_point_pass);

    try testing.expectEqual(PassResult.success, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(usize, 1), FixedPointRerunRunner.runs);
    try testing.expectEqual(@as(usize, 1), RerunIntervalRunner.runs);
    try testing.expectEqual(@as(u64, 2), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_skipped);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
    try testing.expectEqual(@as(usize, 2), counter.pass_count);
}

test "PassManager reruns a fixed-point pass after nested modification" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const func_op = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "rerun_nested", &.{});
    try module_op.getBodyBlock().addOperation(func_op.op);

    FixedPointRerunRunner.runs = 0;
    FixedPointRerunRunner.modify_first = false;
    RerunIntervalRunner.runs = 0;

    const fixed_point_pass = Pass{
        .name = "fixed-point-rerun",
        .description = "",
        .run_fn = FixedPointRerunRunner.run,
        .rerun_policy = .skip_if_unchanged,
    };

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(fixed_point_pass);
    const nested = try pm.nest(test_dialect.TestDialect.FuncOp.operation_name);
    try nested.addPass(.{
        .name = "nested-rerun-revision",
        .description = "",
        .run_fn = RerunIntervalRunner.modify,
    });
    try pm.addPass(fixed_point_pass);

    try testing.expectEqual(PassResult.success, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(usize, 2), FixedPointRerunRunner.runs);
    try testing.expectEqual(@as(usize, 1), RerunIntervalRunner.runs);
    try testing.expectEqual(@as(u64, 3), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_skipped);
    try testing.expectEqual(@as(u64, 1), pm.stats.passes_modified);
}

test "Pass rerun identity is stateless and configuration-specific" {
    const testing = std.testing;

    const base = Pass{
        .name = "fixed-point-rerun",
        .description = "",
        .run_fn = FixedPointRerunRunner.run,
        .rerun_policy = .skip_if_unchanged,
        .textual_options = "mode=base",
    };
    var configured = base;
    configured.textual_options = "mode=other";
    var required = base;
    required.rerun_policy = .always;

    try testing.expect(base.validRerunContract());
    try testing.expect(base.sameRerunIdentity(base));
    try testing.expect(!base.sameRerunIdentity(configured));
    try testing.expect(!base.sameRerunIdentity(required));

    var state: u8 = 0;
    var pm = OpPassManager.init(testing.allocator, null);
    defer pm.deinit();
    try testing.expectError(error.InvalidPassRerunContract, pm.addPass(.{
        .name = "stateful-rerun",
        .description = "",
        .state = &state,
        .run_with_state_fn = StatefulRerunRunner.run,
        .rerun_policy = .skip_if_unchanged,
    }));
}

const StatisticsRunner = struct {
    fn run(ctx: *PassContext) PassResult {
        ctx.incrementStatistic("folds", "folds applied");
        ctx.addStatistic("rewrites", "rewrites applied", 2);
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassContext reports pass statistics through instrumentation" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var statistics = PassStatisticsInstrumentation.init(allocator);
    defer statistics.deinit();

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addInstrumentation(statistics.instrumentation());
    try pm.addPass(.{
        .name = "stat-pass",
        .description = "reports pass statistics",
        .run_fn = StatisticsRunner.run,
        .mutation_scope = .read_only,
    });

    try testing.expectEqual(PassResult.success, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(u64, 1), statistics.get("stat-pass", "folds").?);
    try testing.expectEqual(@as(u64, 2), statistics.get("stat-pass", "rewrites").?);

    const summaries = try statistics.summariesAlloc(allocator);
    defer allocator.free(summaries);
    try testing.expectEqual(@as(usize, 2), summaries.len);
    try testing.expectEqualStrings("stat-pass", summaries[0].pass_name);
    try testing.expectEqualStrings("folds", summaries[0].name);
    try testing.expectEqualStrings("folds applied", summaries[0].description);
    try testing.expectEqual(@as(u64, 1), summaries[0].value);
    try testing.expectEqualStrings("rewrites", summaries[1].name);
    try testing.expectEqual(@as(u64, 2), summaries[1].value);
}

const DuplicateStatisticsRunner = struct {
    fn run(ctx: *PassContext) PassResult {
        ctx.incrementStatistic("matches", "matched operations");
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "Pass statistics aggregate duplicate pass names" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var statistics = PassStatisticsInstrumentation.init(allocator);
    defer statistics.deinit();

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addInstrumentation(statistics.instrumentation());
    try pm.addPass(.{
        .name = "repeat-pass",
        .description = "reports pass statistics",
        .run_fn = DuplicateStatisticsRunner.run,
        .mutation_scope = .read_only,
    });
    try pm.addPass(.{
        .name = "repeat-pass",
        .description = "reports pass statistics again",
        .run_fn = DuplicateStatisticsRunner.run,
        .mutation_scope = .read_only,
    });

    try testing.expectEqual(PassResult.success, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(u64, 2), statistics.get("repeat-pass", "matches").?);

    const summaries = try statistics.summariesAlloc(allocator);
    defer allocator.free(summaries);
    try testing.expectEqual(@as(usize, 1), summaries.len);
    try testing.expectEqualStrings("repeat-pass", summaries[0].pass_name);
    try testing.expectEqualStrings("matches", summaries[0].name);
    try testing.expectEqual(@as(u64, 2), summaries[0].value);
}

const ConfiguredPassState = struct {
    runs: usize = 0,
};

const ConfiguredPassRunner = struct {
    fn run(raw: ?*anyopaque, ctx: *PassContext) PassResult {
        const state: *ConfiguredPassState = @ptrCast(@alignCast(raw orelse return .failure));
        state.runs += 1;
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "Pass state reaches configured run function" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var state = ConfiguredPassState{};
    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(.{
        .name = "stateful-test",
        .description = "records configured pass state",
        .state = &state,
        .run_with_state_fn = ConfiguredPassRunner.run,
        .mutation_scope = .read_only,
    });

    try testing.expectEqual(PassResult.success, pm.run(module_op.op, &ctx));
    try testing.expectEqual(@as(usize, 1), state.runs);
}

const StableFixedPointPass = struct {
    var runs: usize = 0;
    var changed_runs: usize = 0;

    fn run(ctx: *PassContext) PassResult {
        runs += 1;
        if (changed_runs < 2) {
            changed_runs += 1;
            ctx.markModified();
        } else {
            ctx.preserveAllAnalyses();
        }
        return .success;
    }
};

test "PassManager.runToFixedPoint stops after stable iteration" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    StableFixedPointPass.runs = 0;
    StableFixedPointPass.changed_runs = 0;

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(.{
        .name = "fixed-point-test",
        .description = "changes twice before stabilizing",
        .run_fn = StableFixedPointPass.run,
    });

    const result = pm.runToFixedPoint(module_op.op, &ctx, 8);
    try testing.expectEqual(PassResult.success, result.result);
    try testing.expect(result.changed);
    try testing.expectEqual(@as(usize, 3), result.iterations);
    try testing.expectEqual(@as(usize, 3), StableFixedPointPass.runs);
    try testing.expectEqual(@as(usize, 2), StableFixedPointPass.changed_runs);
    try testing.expectEqual(@as(u64, 3), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 2), pm.stats.passes_modified);
}

test "PassManager.runToFixedPoint reports failure" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(.{
        .name = "fixed-point-failure",
        .description = "fails fixed-point execution",
        .run_fn = test_pass_failure,
    });

    const result = pm.runToFixedPoint(module_op.op, &ctx, 8);
    try testing.expectEqual(PassResult.failure, result.result);
    try testing.expect(!result.changed);
    try testing.expectEqual(@as(usize, 1), result.iterations);
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_failures);
}

const HierarchicalFuncCounter = struct {
    var count: usize = 0;

    fn run(ctx: *PassContext) PassResult {
        if (std.mem.eql(u8, ctx.op.name.name, "test.func")) {
            count += 1;
        }
        return .success;
    }
};

test "Hierarchical pass manager runs only on matching ops" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const module_block = module_op.getBodyBlock();

    var builder = ir.OperationBuilder.init(&ctx);
    const target1_state = ir.Operation.State.init("test.target_op", ir.Location.getUnknown());
    const target1_op = try builder.create(target1_state);
    try module_block.addOperation(target1_op);

    const func_op = try test_dialect.TestDialect.FuncOp.create(&ctx, ir.Location.getUnknown(), "nested_func", &.{});
    try module_block.addOperation(func_op.op);

    const func_block = func_op.getEntryBlock();
    const target2_state = ir.Operation.State.init("test.target_op", ir.Location.getUnknown());
    const target2_op = try builder.create(target2_state);
    try func_block.addOperation(target2_op);

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    HierarchicalFuncCounter.count = 0;

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "func-counter",
        .description = "Counts func ops",
        .run_fn = HierarchicalFuncCounter.run,
    });

    const result = pm.run(module_op.op, &ctx);
    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 1), HierarchicalFuncCounter.count);
}

const DeepBinaryCounter = struct {
    var count: usize = 0;

    fn run(ctx: *PassContext) PassResult {
        if (std.mem.eql(u8, ctx.op.name.name, "test.binary")) {
            count += 1;
        }
        return .success;
    }
};

test "Hierarchical pass manager rejects non-isolated deeply nested targets" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const outer_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "outer", &.{});
    try module_block.addOperation(outer_func.op);

    const inner_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "inner", &.{});
    try outer_func.getEntryBlock().addOperation(inner_func.op);

    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    _ = try inner_func.getEntryBlock().addArgument(i32_type, loc);
    _ = try inner_func.getEntryBlock().addArgument(i32_type, loc);
    const inner_args = inner_func.getEntryBlock().arguments.items;
    const binary_op = try test_dialect.TestDialect.BinaryOp.create(&ctx, loc, inner_args[0], inner_args[1]);
    try inner_func.getEntryBlock().addOperation(binary_op.op);

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    DeepBinaryCounter.count = 0;

    const func_pm = try pm.nest("test.func");
    const binary_pm = try func_pm.nest("test.binary");
    try binary_pm.addPass(Pass{
        .name = "binary-counter",
        .description = "Counts binary ops",
        .run_fn = DeepBinaryCounter.run,
    });

    const result = pm.run(module_op.op, &ctx);
    try testing.expectEqual(PassResult.failure, result);
    try testing.expectEqual(@as(usize, 0), DeepBinaryCounter.count);
}

test "Hierarchical pass manager propagates failure" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const module_block = module_op.getBodyBlock();

    const func_op = try test_dialect.TestDialect.FuncOp.create(&ctx, ir.Location.getUnknown(), "fail_func", &.{});
    try module_block.addOperation(func_op.op);

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "failing-pass",
        .description = "Always fails",
        .run_fn = test_pass_failure,
    });

    const result = pm.run(module_op.op, &ctx);
    try testing.expectEqual(PassResult.failure, result);
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_failures);
}

test "PassManager captures serial pass failure reproducer" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    try pm.addPass(Pass{
        .name = "serial-reproducer-fail",
        .description = "fails for reproducer capture",
        .run_fn = test_pass_failure,
    });

    const result = pm.run(module_op.op, &ctx);
    try testing.expectEqual(PassResult.failure, result);

    const reproducer = pm.getLastFailureReproducer() orelse return error.TestExpectedReproducer;
    try testing.expectEqualStrings("serial-reproducer-fail", reproducer.pipeline);
    try testing.expectEqual(@as(usize, 1), reproducer.max_threads);
    try testing.expectEqual(@as(usize, 1), reproducer.worker_count);
    try testing.expect(!reproducer.verifier_enabled);
    try testing.expectEqual(PassFailureKind.pass, reproducer.failure_kind.?);
    try testing.expectEqualStrings("serial-reproducer-fail", reproducer.pass_name.?);
    try testing.expectEqualStrings(module_op.op.name.name, reproducer.target_op_name.?);
    try testing.expect(std.mem.indexOf(u8, reproducer.ir, module_op.op.name.name) != null);
}

const NestedPassOrderTracker = struct {
    var order: [3]u8 = undefined;
    var idx: usize = 0;

    fn pass1(_: *PassContext) PassResult {
        order[idx] = '1';
        idx += 1;
        return .success;
    }

    fn pass2(_: *PassContext) PassResult {
        order[idx] = '2';
        idx += 1;
        return .success;
    }

    fn pass3(_: *PassContext) PassResult {
        order[idx] = '3';
        idx += 1;
        return .success;
    }
};

test "Multiple passes in nested manager run sequentially" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    const module_block = module_op.getBodyBlock();

    const func_op = try test_dialect.TestDialect.FuncOp.create(&ctx, ir.Location.getUnknown(), "multi_pass", &.{});
    try module_block.addOperation(func_op.op);

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    NestedPassOrderTracker.idx = 0;

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "pass1",
        .description = "",
        .run_fn = NestedPassOrderTracker.pass1,
    });
    try func_pm.addPass(Pass{
        .name = "pass2",
        .description = "",
        .run_fn = NestedPassOrderTracker.pass2,
    });
    try func_pm.addPass(Pass{
        .name = "pass3",
        .description = "",
        .run_fn = NestedPassOrderTracker.pass3,
    });

    const result = pm.run(module_op.op, &ctx);
    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 3), NestedPassOrderTracker.idx);
    try testing.expectEqualStrings("123", &NestedPassOrderTracker.order);
}

const ReadOnlyParallelBarrierPass = struct {
    var started = std.atomic.Value(usize).init(0);
    var release = std.atomic.Value(bool).init(false);

    fn run(ctx: *PassContext) PassResult {
        if (ctx.workerCount(8) != 2) return .failure;
        if (!ctx.ir_ctx.isMultithreadedExecution()) return .failure;
        ctx.preserveAllAnalyses();
        const arrived = started.fetchAdd(1, .acq_rel) + 1;
        if (arrived == 2) release.store(true, .release);

        var spins: usize = 0;
        while (!release.load(.acquire)) {
            spins += 1;
            if (spins > 1_000_000) return .failure;
            sys.thread.yield();
        }
        return .success;
    }
};

test "PassManager.runWithOptions runs read-only nested targets concurrently" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    const second_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "second", &.{});
    try module_block.addOperation(second_func.op);

    ReadOnlyParallelBarrierPass.started.store(0, .release);
    ReadOnlyParallelBarrierPass.release.store(false, .release);

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "barrier-read-only",
        .description = "waits for another read-only target",
        .run_fn = ReadOnlyParallelBarrierPass.run,
        .mutation_scope = .read_only,
    });

    const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 2), ReadOnlyParallelBarrierPass.started.load(.acquire));
    try testing.expectEqual(@as(u64, 2), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.pass_failures);
}

const ParallelContextStoragePass = struct {
    var attr_value: i64 = 0;

    fn run(ctx: *PassContext) PassResult {
        if (!ctx.ir_ctx.isMultithreadedExecution()) return .failure;
        _ = ctx.ir_ctx.getI64Attr(attr_value) catch return .failure;
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.runWithOptions blocks context storage misses in parallel read-only passes" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    const second_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "second", &.{});
    try module_block.addOperation(second_func.op);

    _ = try ctx.getI64Attr(7);
    ParallelContextStoragePass.attr_value = 7;

    var preload_pm = PassManager.init(allocator);
    defer preload_pm.deinit();
    const preload_func_pm = try preload_pm.nest("test.func");
    try preload_func_pm.addPass(Pass{
        .name = "preloaded-context-storage",
        .description = "reads preloaded context storage",
        .run_fn = ParallelContextStoragePass.run,
        .mutation_scope = .read_only,
    });

    const preload_result = preload_pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.success, preload_result);
    try testing.expectEqual(@as(u64, 2), preload_pm.stats.pass_runs);

    ParallelContextStoragePass.attr_value = 8;

    var miss_pm = PassManager.init(allocator);
    defer miss_pm.deinit();
    const miss_func_pm = try miss_pm.nest("test.func");
    try miss_func_pm.addPass(Pass{
        .name = "missing-context-storage",
        .description = "attempts context storage creation",
        .run_fn = ParallelContextStoragePass.run,
        .mutation_scope = .read_only,
    });

    const miss_result = miss_pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.failure, miss_result);
    try testing.expectEqual(@as(u64, 2), miss_pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 2), miss_pm.stats.pass_failures);
}

const ParallelReproducerFailingPass = struct {
    fn run(ctx: *PassContext) PassResult {
        if (!ctx.ir_ctx.isMultithreadedExecution()) return .failure;
        return .failure;
    }
};

test "PassManager.runWithOptions captures parallel pass failure reproducer in target order" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    const second_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "second", &.{});
    try module_block.addOperation(second_func.op);

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "parallel-reproducer-fail",
        .description = "fails on each read-only target",
        .run_fn = ParallelReproducerFailingPass.run,
        .mutation_scope = .read_only,
    });

    const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.failure, result);

    const reproducer = pm.getLastFailureReproducer() orelse return error.TestExpectedReproducer;
    try testing.expectEqualStrings("test.func(parallel-reproducer-fail)", reproducer.pipeline);
    try testing.expectEqual(@as(usize, 2), reproducer.max_threads);
    try testing.expectEqual(@as(usize, 2), reproducer.worker_count);
    try testing.expectEqual(PassFailureKind.pass, reproducer.failure_kind.?);
    try testing.expectEqualStrings("parallel-reproducer-fail", reproducer.pass_name.?);
    try testing.expectEqualStrings("test.func", reproducer.target_op_name.?);
    try testing.expectEqualStrings("first", reproducer.target_symbol_name.?);
    try testing.expect(std.mem.indexOf(u8, reproducer.ir, "second") != null);
}

const ParallelDiagnosticRecorder = struct {
    messages: [2][]const u8 = .{ "", "" },
    seen: usize = 0,

    fn handle(
        context: ?*anyopaque,
        diagnostic: *const diagnostics.Diagnostic,
    ) !diagnostics.HandlerResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.messages[self.seen] = diagnostic.message;
        self.seen += 1;
        return .consumed;
    }
};

const ParallelDiagnosticPass = struct {
    var second_emitted = std.atomic.Value(bool).init(false);

    fn run(ctx: *PassContext) PassResult {
        const symbol_name = ir.SymbolTable.getSymbolName(ctx.op) orelse return .failure;
        const is_first = std.mem.eql(u8, symbol_name, "first");
        if (is_first) {
            var spins: usize = 0;
            while (!second_emitted.load(.acquire)) {
                spins += 1;
                if (spins > 1_000_000) return .failure;
                sys.thread.yield();
            }
        }

        const message: []const u8 = if (is_first) "first diagnostic" else "second diagnostic";
        var diagnostic = ctx.op.emitWarning(message);
        defer diagnostic.deinit();
        _ = diagnostic.emit() catch return .failure;

        if (!is_first) second_emitted.store(true, .release);
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.runWithOptions replays parallel diagnostics in target order" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    const second_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "second", &.{});
    try module_block.addOperation(second_func.op);

    var recorder = ParallelDiagnosticRecorder{};
    _ = try ctx.registerDiagnosticHandler(.{
        .context = &recorder,
        .handle = ParallelDiagnosticRecorder.handle,
    });
    ParallelDiagnosticPass.second_emitted.store(false, .release);

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "diagnostic-order-check",
        .description = "emits diagnostics in scheduling-inverted order",
        .run_fn = ParallelDiagnosticPass.run,
        .mutation_scope = .read_only,
    });

    const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 2), recorder.seen);
    try testing.expectEqualStrings("first diagnostic", recorder.messages[0]);
    try testing.expectEqualStrings("second diagnostic", recorder.messages[1]);
}

const VerifierParallelBarrierPass = struct {
    var started = std.atomic.Value(usize).init(0);
    var release = std.atomic.Value(bool).init(false);

    fn run(ctx: *PassContext) PassResult {
        if (!ctx.ir_ctx.isMultithreadedExecution()) return .failure;
        ctx.preserveAllAnalyses();
        const arrived = started.fetchAdd(1, .acq_rel) + 1;
        if (arrived == 2) release.store(true, .release);

        var spins: usize = 0;
        while (!release.load(.acquire)) {
            spins += 1;
            if (spins > 1_000_000) return .failure;
            sys.thread.yield();
        }
        return .success;
    }
};

test "PassManager.runWithOptions keeps read-only targets parallel with verifier enabled" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    const second_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "second", &.{});
    try module_block.addOperation(second_func.op);

    VerifierParallelBarrierPass.started.store(0, .release);
    VerifierParallelBarrierPass.release.store(false, .release);

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    pm.enableVerifier();

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "verifier-parallel-barrier",
        .description = "waits for another verified read-only target",
        .run_fn = VerifierParallelBarrierPass.run,
        .mutation_scope = .read_only,
    });

    const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 2), VerifierParallelBarrierPass.started.load(.acquire));
    try testing.expectEqual(@as(u64, 2), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.verifier_failures);
    try testing.expect(pm.getLastVerifierFailure() == null);
}

const ExclusivePassState = struct {
    runs: usize = 0,
};

const ExclusiveStateSerialPass = struct {
    fn run(raw: ?*anyopaque, ctx: *PassContext) PassResult {
        if (ctx.ir_ctx.isMultithreadedExecution()) return .failure;
        const state: *ExclusivePassState = @ptrCast(@alignCast(raw orelse return .failure));
        state.runs += 1;
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.runWithOptions keeps exclusive stateful read-only passes serial" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    const second_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "second", &.{});
    try module_block.addOperation(second_func.op);

    var state = ExclusivePassState{};
    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "exclusive-state-serial-check",
        .description = "records serial exclusive state",
        .state = &state,
        .run_with_state_fn = ExclusiveStateSerialPass.run,
        .mutation_scope = .read_only,
    });

    const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 2), state.runs);
}

const SharedPassState = struct {
    started: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const SharedStateParallelPass = struct {
    fn run(raw: ?*anyopaque, ctx: *PassContext) PassResult {
        if (!ctx.ir_ctx.isMultithreadedExecution()) return .failure;
        const state: *SharedPassState = @ptrCast(@alignCast(raw orelse return .failure));
        const arrived = state.started.fetchAdd(1, .acq_rel) + 1;
        if (arrived == 2) state.release.store(true, .release);

        var spins: usize = 0;
        while (!state.release.load(.acquire)) {
            spins += 1;
            if (spins > 1_000_000) return .failure;
            sys.thread.yield();
        }
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.runWithOptions runs shared stateful read-only passes in parallel" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    const second_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "second", &.{});
    try module_block.addOperation(second_func.op);

    var state = SharedPassState{};
    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "shared-state-parallel-check",
        .description = "coordinates through explicit shared state",
        .state = &state,
        .run_with_state_fn = SharedStateParallelPass.run,
        .state_concurrency = .shared,
        .mutation_scope = .read_only,
    });

    const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 2), state.started.load(.acquire));
}

const ClonedPassStats = struct {
    clones: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    deinit_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    runs: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    started: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const ClonedPassState = struct {
    stats: *ClonedPassStats,
    original: bool,
    runs: usize = 0,
};

const ClonedStateParallelPass = struct {
    fn clone(raw: ?*anyopaque, clone_allocator: std.mem.Allocator) anyerror!?*anyopaque {
        const state = raw orelse return error.TestMissingState;
        const original: *ClonedPassState = @ptrCast(@alignCast(state));
        const cloned = try clone_allocator.create(ClonedPassState);
        cloned.* = .{
            .stats = original.stats,
            .original = false,
        };
        _ = original.stats.clones.fetchAdd(1, .acq_rel);
        return cloned;
    }

    fn deinit(raw: ?*anyopaque, deinit_allocator: std.mem.Allocator) void {
        const state: *ClonedPassState = @ptrCast(@alignCast(raw orelse return));
        _ = state.stats.deinit_count.fetchAdd(1, .acq_rel);
        deinit_allocator.destroy(state);
    }

    fn run(raw: ?*anyopaque, ctx: *PassContext) PassResult {
        if (!ctx.ir_ctx.isMultithreadedExecution()) return .failure;
        const state: *ClonedPassState = @ptrCast(@alignCast(raw orelse return .failure));
        if (state.original) return .failure;
        if (state.runs != 0) return .failure;
        state.runs += 1;
        _ = state.stats.runs.fetchAdd(1, .acq_rel);

        const arrived = state.stats.started.fetchAdd(1, .acq_rel) + 1;
        if (arrived == 2) state.stats.release.store(true, .release);

        var spins: usize = 0;
        while (!state.stats.release.load(.acquire)) {
            spins += 1;
            if (spins > 1_000_000) return .failure;
            sys.thread.yield();
        }
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.runWithOptions clones stateful read-only passes for parallel targets" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    const second_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "second", &.{});
    try module_block.addOperation(second_func.op);

    var stats = ClonedPassStats{};
    const original = try allocator.create(ClonedPassState);
    original.* = .{
        .stats = &stats,
        .original = true,
    };

    var pm = PassManager.init(allocator);
    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "cloned-state-parallel-check",
        .description = "runs with cloned state per target",
        .state = original,
        .run_with_state_fn = ClonedStateParallelPass.run,
        .state_clone_fn = ClonedStateParallelPass.clone,
        .state_deinit_fn = ClonedStateParallelPass.deinit,
        .mutation_scope = .read_only,
    });

    const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 2), stats.clones.load(.acquire));
    try testing.expectEqual(@as(usize, 2), stats.runs.load(.acquire));
    try testing.expectEqual(@as(usize, 2), stats.deinit_count.load(.acquire));

    pm.deinit();
    try testing.expectEqual(@as(usize, 3), stats.deinit_count.load(.acquire));
}

const ParallelVerifierReadOnlyPass = struct {
    fn run(ctx: *PassContext) PassResult {
        ctx.preserveAllAnalyses();
        return .success;
    }
};

const ParallelFixedPointRerunPass = struct {
    var runs = std.atomic.Value(usize).init(0);

    fn run(ctx: *PassContext) PassResult {
        if (!ctx.ir_ctx.isMultithreadedExecution()) return .failure;
        _ = runs.fetchAdd(1, .acq_rel);
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.runWithOptions merges parallel fixed-point skips" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();
    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    const second_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "second", &.{});
    try module_block.addOperation(second_func.op);

    ParallelFixedPointRerunPass.runs.store(0, .release);

    const rerun_pass = Pass{
        .name = "parallel-fixed-point-rerun",
        .description = "",
        .run_fn = ParallelFixedPointRerunPass.run,
        .mutation_scope = .read_only,
        .rerun_policy = .skip_if_unchanged,
    };

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    const func_pm = try pm.nest(test_dialect.TestDialect.FuncOp.operation_name);
    try func_pm.addPass(rerun_pass);
    try func_pm.addPass(rerun_pass);

    const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 2), ParallelFixedPointRerunPass.runs.load(.acquire));
    try testing.expectEqual(@as(u64, 2), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 2), pm.stats.passes_skipped);
}

test "PassManager.runWithOptions merges parallel verifier failures in target order" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    try appendInvalidTestConstantToBlock(&ctx, first_func.getEntryBlock());

    const nested_module = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    try module_block.addOperation(nested_module.op);
    try appendInvalidTestConstantToBlock(&ctx, nested_module.getBodyBlock());

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    pm.enableVerifier();

    const any_pm = try pm.nestAny();
    try any_pm.addPass(Pass{
        .name = "read-only-verify-check",
        .description = "lets verifier inspect preexisting invalid IR",
        .run_fn = ParallelVerifierReadOnlyPass.run,
        .mutation_scope = .read_only,
    });

    const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 2 });
    try testing.expectEqual(PassResult.failure, result);
    try testing.expectEqual(@as(u64, 2), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 2), pm.stats.verifier_failures);

    const failure = pm.getLastVerifierFailure() orelse return error.TestExpectedVerifierFailure;
    try testing.expectEqualStrings("read-only-verify-check", failure.pass_name);
    try testing.expectEqualStrings(test_dialect.TestDialect.FuncOp.operation_name, failure.target_op_name);
    try testing.expectEqual(error.MissingRequiredAttribute, failure.err);
}

const parallel_stress_target_count = 12;

const ParallelStressRecorder = struct {
    symbols: [parallel_stress_target_count][]const u8 = undefined,
    seen: usize = 0,

    fn handle(
        context: ?*anyopaque,
        diagnostic: *const diagnostics.Diagnostic,
    ) !diagnostics.HandlerResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const op = diagnostic.operation orelse return error.TestMissingDiagnosticOperation;
        const symbol = ir.SymbolTable.getSymbolName(op) orelse return error.TestMissingSymbol;
        self.symbols[self.seen] = symbol;
        self.seen += 1;
        return .consumed;
    }
};

const ParallelStressPassState = struct {
    attr_value: i64,
    started: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    total_runs: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

const ParallelStressPass = struct {
    fn run(raw: ?*anyopaque, ctx: *PassContext) PassResult {
        const state: *ParallelStressPassState = @ptrCast(@alignCast(raw orelse return .failure));
        if (!ctx.ir_ctx.isMultithreadedExecution()) return .failure;
        if (ctx.workerCount(parallel_stress_target_count) < 2) return .failure;
        _ = ctx.ir_ctx.getI64Attr(state.attr_value) catch return .failure;

        const arrived = state.started.fetchAdd(1, .acq_rel) + 1;
        if (arrived == 2) state.release.store(true, .release);

        var spins: usize = 0;
        while (!state.release.load(.acquire)) {
            spins += 1;
            if (spins > 1_000_000) return .failure;
            sys.thread.yield();
        }

        var diagnostic = ctx.op.emitWarning("parallel stress target");
        defer diagnostic.deinit();
        _ = diagnostic.emit() catch return .failure;

        _ = state.total_runs.fetchAdd(1, .acq_rel);
        ctx.preserveAllAnalyses();
        return .success;
    }
};

const ParallelStressForcedFailurePass = struct {
    fn run(ctx: *PassContext) PassResult {
        const symbol = ir.SymbolTable.getSymbolName(ctx.op) orelse return .failure;
        ctx.preserveAllAnalyses();
        if (std.mem.eql(u8, symbol, "fail_7")) return .failure;
        return .success;
    }
};

const ParallelStressReadOnlyPass = struct {
    fn run(ctx: *PassContext) PassResult {
        ctx.preserveAllAnalyses();
        return .success;
    }
};

const ParallelStressStorageMissPass = struct {
    fn run(ctx: *PassContext) PassResult {
        _ = ctx.ir_ctx.getI64Attr(9999) catch return .failure;
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.runWithOptions stresses read-only parallel target runs" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    for (0..4) |iteration| {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ctx.deinit(allocator);
        try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);
        _ = try ctx.getI64Attr(@intCast(40 + iteration));

        var recorder = ParallelStressRecorder{};
        _ = try ctx.registerDiagnosticHandler(.{
            .context = &recorder,
            .handle = ParallelStressRecorder.handle,
        });

        const loc = ir.Location.getUnknown();
        const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
        const module_block = module_op.getBodyBlock();
        var expected_symbols: [parallel_stress_target_count][]const u8 = undefined;

        for (0..parallel_stress_target_count) |slot| {
            const ordinal = (slot * 5 + iteration * 3) % parallel_stress_target_count;
            const name = try std.fmt.allocPrint(allocator, "stress_{d}_{d}", .{ iteration, ordinal });
            expected_symbols[slot] = name;
            const func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, name, &.{});
            try module_block.addOperation(func.op);
        }

        var state = ParallelStressPassState{ .attr_value = @intCast(40 + iteration) };
        var pm = PassManager.init(allocator);
        defer pm.deinit();
        pm.enableVerifier();

        const func_pm = try pm.nest(test_dialect.TestDialect.FuncOp.operation_name);
        try func_pm.addPass(Pass{
            .name = "stress-read-only-parallel",
            .description = "stress read-only parallel target execution",
            .state = &state,
            .run_with_state_fn = ParallelStressPass.run,
            .state_concurrency = .shared,
            .mutation_scope = .read_only,
        });

        const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 4 });
        try testing.expectEqual(PassResult.success, result);
        try testing.expectEqual(@as(u64, parallel_stress_target_count), pm.stats.pass_runs);
        try testing.expectEqual(@as(u64, 0), pm.stats.pass_failures);
        try testing.expectEqual(@as(u64, 0), pm.stats.verifier_failures);
        try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
        try testing.expectEqual(
            @as(usize, parallel_stress_target_count),
            state.total_runs.load(.acquire),
        );
        try testing.expectEqual(@as(usize, parallel_stress_target_count), recorder.seen);
        for (expected_symbols, 0..) |expected, index| {
            try testing.expectEqualStrings(expected, recorder.symbols[index]);
        }
    }

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ctx.deinit(allocator);
        try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

        const loc = ir.Location.getUnknown();
        const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
        const module_block = module_op.getBodyBlock();
        for (0..parallel_stress_target_count) |index| {
            const name = try std.fmt.allocPrint(allocator, "fail_{d}", .{index});
            const func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, name, &.{});
            try module_block.addOperation(func.op);
        }

        var pm = PassManager.init(allocator);
        defer pm.deinit();
        const func_pm = try pm.nest(test_dialect.TestDialect.FuncOp.operation_name);
        try func_pm.addPass(Pass{
            .name = "stress-forced-failure",
            .description = "fails one parallel target",
            .run_fn = ParallelStressForcedFailurePass.run,
            .mutation_scope = .read_only,
        });

        const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 4 });
        try testing.expectEqual(PassResult.failure, result);
        try testing.expectEqual(@as(u64, parallel_stress_target_count), pm.stats.pass_runs);
        try testing.expectEqual(@as(u64, 1), pm.stats.pass_failures);

        const reproducer = pm.getLastFailureReproducer() orelse return error.TestExpectedReproducer;
        try testing.expectEqual(PassFailureKind.pass, reproducer.failure_kind.?);
        try testing.expectEqualStrings("fail_7", reproducer.target_symbol_name.?);
    }

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ctx.deinit(allocator);
        try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

        const loc = ir.Location.getUnknown();
        const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
        const module_block = module_op.getBodyBlock();
        var invalid_targets: u64 = 0;
        for (0..parallel_stress_target_count) |index| {
            const name = try std.fmt.allocPrint(allocator, "verify_{d}", .{index});
            const func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, name, &.{});
            try module_block.addOperation(func.op);
            if (index % 3 == 1) {
                try appendInvalidTestConstantToBlock(&ctx, func.getEntryBlock());
                invalid_targets += 1;
            }
        }

        var pm = PassManager.init(allocator);
        defer pm.deinit();
        pm.enableVerifier();
        const func_pm = try pm.nest(test_dialect.TestDialect.FuncOp.operation_name);
        try func_pm.addPass(Pass{
            .name = "stress-verifier-failure",
            .description = "lets verifier fail invalid parallel targets",
            .run_fn = ParallelStressReadOnlyPass.run,
            .mutation_scope = .read_only,
        });

        const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 4 });
        try testing.expectEqual(PassResult.failure, result);
        try testing.expectEqual(@as(u64, parallel_stress_target_count), pm.stats.pass_runs);
        try testing.expectEqual(invalid_targets, pm.stats.verifier_failures);

        const reproducer = pm.getLastFailureReproducer() orelse return error.TestExpectedReproducer;
        try testing.expectEqual(PassFailureKind.verifier, reproducer.failure_kind.?);
        try testing.expectEqual(error.MissingRequiredAttribute, reproducer.verifier_error.?);
        try testing.expectEqualStrings("MissingRequiredAttribute", reproducer.verifier_error_name.?);
    }

    {
        var arena = alloc_arena.Arena.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ctx.deinit(allocator);
        try ir.dialects.loadDialectSpec(&ctx, test_dialect.TestDialect.spec);

        const loc = ir.Location.getUnknown();
        const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
        const module_block = module_op.getBodyBlock();
        for (0..4) |index| {
            const name = try std.fmt.allocPrint(allocator, "miss_{d}", .{index});
            const func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, name, &.{});
            try module_block.addOperation(func.op);
        }

        var pm = PassManager.init(allocator);
        defer pm.deinit();
        const func_pm = try pm.nest(test_dialect.TestDialect.FuncOp.operation_name);
        try func_pm.addPass(Pass{
            .name = "stress-context-storage-miss",
            .description = "fails on context storage miss",
            .run_fn = ParallelStressStorageMissPass.run,
            .mutation_scope = .read_only,
        });

        const result = pm.runWithOptions(module_op.op, &ctx, .{ .max_threads = 4 });
        try testing.expectEqual(PassResult.failure, result);
        try testing.expectEqual(@as(u64, 4), pm.stats.pass_runs);
        try testing.expectEqual(@as(u64, 4), pm.stats.pass_failures);
    }
}

const SerialThreadingCheckPass = struct {
    fn run(ctx: *PassContext) PassResult {
        if (ctx.ir_ctx.isMultithreadedExecution()) return .failure;
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.run keeps serial passes outside multithreaded execution" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(Pass{
        .name = "serial-threading-check",
        .description = "checks serial context execution state",
        .run_fn = SerialThreadingCheckPass.run,
        .mutation_scope = .read_only,
    });

    const result = pm.run(module_op.op, &ctx);
    try testing.expectEqual(PassResult.success, result);
}

const WorkerAllocatorCheckPass = struct {
    var expected: std.mem.Allocator = undefined;
    var seen = std.atomic.Value(usize).init(0);

    fn run(ctx: *PassContext) PassResult {
        if (ctx.allocator.ptr != expected.ptr) return .failure;
        if (ctx.allocator.vtable != expected.vtable) return .failure;
        const marker = ctx.allocator.create(u32) catch return .failure;
        ctx.allocator.destroy(marker);
        ctx.preserveAllAnalyses();
        _ = seen.fetchAdd(1, .acq_rel);
        return .success;
    }
};

test "PassManager.runWithOptions uses configured worker allocator for read-only targets" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const first_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "first", &.{});
    try module_block.addOperation(first_func.op);
    const second_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "second", &.{});
    try module_block.addOperation(second_func.op);

    WorkerAllocatorCheckPass.seen.store(0, .release);

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "worker-allocator-check",
        .description = "checks read-only worker allocator",
        .run_fn = WorkerAllocatorCheckPass.run,
        .mutation_scope = .read_only,
    });

    var worker_gpa = alloc_observe.debug.Allocator(.{}).init(
        testing.allocator,
    );
    defer {
        const status = worker_gpa.deinit();
        testing.expect(status == .ok) catch @panic("pass worker allocator leaked allocations");
    }
    const worker_allocator = worker_gpa.allocator();
    WorkerAllocatorCheckPass.expected = worker_allocator;

    const result = pm.runWithOptions(module_op.op, &ctx, .{
        .max_threads = 2,
        .worker_allocator = worker_allocator,
    });
    try testing.expectEqual(PassResult.success, result);
    try testing.expectEqual(@as(usize, 2), WorkerAllocatorCheckPass.seen.load(.acquire));
}

const RunOptionsCheckPass = struct {
    var expected_allocator: std.mem.Allocator = undefined;

    fn run(ctx: *PassContext) PassResult {
        if (ctx.workerCount(8) != 3) return .failure;
        const worker_allocator = ctx.workerAllocator();
        if (worker_allocator.ptr != expected_allocator.ptr) return .failure;
        if (worker_allocator.vtable != expected_allocator.vtable) return .failure;
        ctx.preserveAllAnalyses();
        return .success;
    }
};

test "PassManager.runWithOptions exposes options to pass context" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var pm = PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(Pass{
        .name = "option-check",
        .description = "checks pass context run options",
        .run_fn = RunOptionsCheckPass.run,
        .mutation_scope = .read_only,
    });

    var worker_gpa = alloc_observe.debug.Allocator(.{}).init(
        testing.allocator,
    );
    defer {
        const status = worker_gpa.deinit();
        testing.expect(status == .ok) catch @panic("pass option worker allocator leaked allocations");
    }
    const worker_allocator = worker_gpa.allocator();
    RunOptionsCheckPass.expected_allocator = worker_allocator;

    const result = pm.runWithOptions(module_op.op, &ctx, .{
        .max_threads = 3,
        .worker_allocator = worker_allocator,
    });
    try testing.expectEqual(PassResult.success, result);
}

const SameTypeFuncCounter = struct {
    var count: usize = 0;

    fn run(ctx: *PassContext) PassResult {
        if (std.mem.eql(u8, ctx.op.name.name, "test.func")) {
            count += 1;
        }
        return .success;
    }
};

test "Same-type nesting: func inside func both processed" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_block = module_op.getBodyBlock();

    const outer_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "outer", &.{});
    try module_block.addOperation(outer_func.op);

    const inner_func = try test_dialect.TestDialect.FuncOp.create(&ctx, loc, "inner", &.{});
    try outer_func.getEntryBlock().addOperation(inner_func.op);

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    SameTypeFuncCounter.count = 0;

    const func_pm = try pm.nest("test.func");
    try func_pm.addPass(Pass{
        .name = "func-counter",
        .description = "Counts func ops",
        .run_fn = SameTypeFuncCounter.run,
    });

    const result = pm.run(module_op.op, &ctx);
    try testing.expectEqual(PassResult.success, result);

    try testing.expectEqual(@as(usize, 2), SameTypeFuncCounter.count);
}

test "PassManager with instrumentation invokes hooks" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    var counter = CountingInstrumentation{};
    try pm.addInstrumentation(counter.instrumentation());

    try pm.addPass(Pass{
        .name = "noop-pass",
        .description = "Does nothing",
        .run_fn = test_pass_success,
    });

    const result = pm.run(module_op.op, &ctx);
    try testing.expectEqual(PassResult.success, result);

    try testing.expectEqual(@as(usize, 1), counter.pipeline_count);
    try testing.expectEqual(@as(usize, 1), counter.pass_count);
    try testing.expectEqual(@as(usize, 0), counter.pass_failures);
}

test "PassManager timing instrumentation" {
    const testing = std.testing;
    const test_dialect = @import("../../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());

    var pm = PassManager.init(allocator);
    defer pm.deinit();

    var timing = TimingInstrumentation.init(allocator);
    defer timing.deinit();
    try pm.addInstrumentation(timing.instrumentation());

    try pm.addPass(Pass{
        .name = "timed-pass",
        .description = "Timed pass",
        .run_fn = test_pass_success,
    });

    const result = pm.run(module_op.op, &ctx);
    try testing.expectEqual(PassResult.success, result);

    try testing.expect(timing.getPassCount("timed-pass") != null);
    try testing.expectEqual(@as(u64, 1), timing.getPassCount("timed-pass").?);
    try testing.expect(timing.hasPipelineTimings());

    const pipeline_summaries = try timing.pipelineSummariesAlloc(allocator);
    try testing.expectEqual(@as(usize, 1), pipeline_summaries.len);
    try testing.expectEqual(@as(?[]const u8, null), pipeline_summaries[0].target);
    try testing.expectEqual(@as(usize, 0), pipeline_summaries[0].depth);
    try testing.expect(pipeline_summaries[0].total_ns >= 0);
}

fn meteredAnalysisBounds(_: subject.work.Input) !subject.work.Bounds {
    return .{
        .work = .{
            .analysis_computations = 1,
            .structural_visits = 5,
            .allocation_capacity = 4096,
        },
        .workspace = 4096,
    };
}

test "U0 analysis admission refuses before computation and keeps the exhausted charge" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, ir.Location.getUnknown());
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{
            .structural_visits = 4,
            .analysis_computations = 1,
            .allocation_capacity = 65536,
        },
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var stats: PassManagerStats = .{};
    var cache = try AnalysisCache.initAccounted(allocator, &stats, ledger, .{}, 4);
    defer cache.deinit();
    var notifications = CountingInstrumentation{};
    var instrumentor = PassInstrumentor.init(allocator);
    defer instrumentor.deinit();
    try instrumentor.addInstrumentation(notifications.instrumentation());
    var ctx = PassContext.initWithInstrumentor(
        module.op,
        &context,
        allocator,
        &cache,
        &instrumentor,
    );
    defer ctx.deinit();
    const descriptor = AnalysisDescriptor{
        .id = analysisId("u0-metered-analysis"),
        .name = "u0-metered-analysis",
        .work_contract = .{
            .identity = .{ .name = "u0-metered-analysis", .version = 1 },
            .estimate = meteredAnalysisBounds,
        },
    };
    analysis_counter = 0;
    const result = ctx.getAnalysis(module.op, &descriptor, computeCounter, cleanupCounter);
    try std.testing.expectError(error.WorkExhausted, result);
    try std.testing.expectEqual(0, analysis_counter);
    try std.testing.expectEqual(0, stats.analysis_misses);
    try std.testing.expectEqual(0, notifications.analysis_count);
    try std.testing.expectEqual(.exhausted, ledger.view().outcome);
    try std.testing.expectEqual(5, ledger.view().charged.structural_visits);
    try std.testing.expectEqual(0, cache.entries.count());
}

test "U0 analysis accounting records computations and hits without charging a second computation" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, ir.Location.getUnknown());
    const pipeline = [_]revision.record.Version{.{ .name = "host", .version = 1 }};
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{
            .structural_visits = 6,
            .analysis_computations = 1,
            .allocation_capacity = 65536,
        },
        .workspace = 4096,
        .events = 8,
    }, &pipeline);
    defer ledger.destroy();
    var stats: PassManagerStats = .{};
    var cache = try AnalysisCache.initAccounted(allocator, &stats, ledger, .{}, 4);
    defer cache.deinit();
    const parent = try ledger.begin(.pass, .{
        .identity = pipeline[0],
        .work = .{ .structural_visits = 1 },
    });
    var ctx = PassContext.init(module.op, &context, allocator, &cache);
    defer ctx.deinit();
    const descriptor = AnalysisDescriptor{
        .id = analysisId("u0-metered-analysis"),
        .name = "u0-metered-analysis",
        .work_contract = .{
            .identity = .{ .name = "u0-metered-analysis", .version = 1 },
            .estimate = meteredAnalysisBounds,
        },
    };
    analysis_counter = 0;
    const first = try ctx.getAnalysis(module.op, &descriptor, computeCounter, cleanupCounter);
    const second = try ctx.getAnalysis(module.op, &descriptor, computeCounter, cleanupCounter);
    try ledger.finish(parent, .success, .{ .counters = .{ .pass_runs = 1 } });
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(1, analysis_counter);
    try std.testing.expectEqual(1, ledger.view().charged.analysis_computations);
    try std.testing.expectEqual(
        stats.analysis_misses,
        ledger.view().executed.counters.analysis_misses,
    );
    try std.testing.expectEqual(stats.analysis_hits, ledger.view().executed.counters.analysis_hits);
    try std.testing.expectEqual(1, ledger.view().events[parent].executed.counters.analysis_hits);
    try std.testing.expectEqual(.analysis, ledger.view().events[2].phase);
    try std.testing.expectEqual(parent, ledger.view().events[2].parent.?);
    try std.testing.expectEqual(1, ledger.view().executed.counters.pass_runs);
    try ledger.producersComplete();
}

test "U0 analysis missing contract permits transient computation and refuses qualification" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, ir.Location.getUnknown());
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{ .allocation_capacity = 65536 },
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var cache = try AnalysisCache.initAccounted(allocator, null, ledger, .{}, 4);
    defer cache.deinit();
    var ctx = PassContext.init(module.op, &context, allocator, &cache);
    defer ctx.deinit();
    const descriptor = AnalysisDescriptor{
        .id = analysisId("u0-unmetered-analysis"),
        .name = "u0-unmetered-analysis",
    };
    analysis_counter = 0;
    _ = try ctx.getAnalysis(module.op, &descriptor, computeCounter, cleanupCounter);
    try std.testing.expectEqual(1, analysis_counter);
    try std.testing.expectEqual(1, ledger.view().executed.counters.analysis_misses);
    try std.testing.expectError(error.MissingWorkContract, ledger.producersComplete());
    try std.testing.expect(ledger.view().missing_work_contract);
    try std.testing.expectEqual(1, ledger.view().events.len);
}

fn computeMeteredTyped(ctx: *PassContext, op: *ir.Operation) anyerror!*anyopaque {
    return @ptrCast(try computeTypedCounter(ctx, op));
}

fn cleanupMeteredTyped(value: *anyopaque, allocator: std.mem.Allocator) void {
    cleanupTypedCounter(@ptrCast(@alignCast(value)), allocator);
}

test "U0 analysis computation failure stays charged and cannot retry the same request" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, ir.Location.getUnknown());
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{
            .structural_visits = 5,
            .analysis_computations = 1,
            .allocation_capacity = 65536,
        },
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    var stats: PassManagerStats = .{};
    var cache = try AnalysisCache.initAccounted(failing.allocator(), &stats, ledger, .{}, 4);
    defer cache.deinit();
    var ctx = PassContext.init(module.op, &context, failing.allocator(), &cache);
    defer ctx.deinit();
    const descriptor = AnalysisDescriptor{
        .id = analysisId("u0-metered-analysis"),
        .name = "u0-metered-analysis",
        .work_contract = .{
            .identity = .{ .name = "u0-metered-analysis", .version = 1 },
            .estimate = meteredAnalysisBounds,
        },
    };
    typed_analysis_counter = 0;
    typed_analysis_cleanup_count = 0;
    try std.testing.expectError(
        error.OutOfMemory,
        ctx.getAnalysis(module.op, &descriptor, computeMeteredTyped, cleanupMeteredTyped),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(1, typed_analysis_counter);
    try std.testing.expectEqual(0, typed_analysis_cleanup_count);
    try std.testing.expectEqual(0, cache.entries.count());
    try std.testing.expectEqual(.rejected, ledger.view().outcome);
    try std.testing.expectEqual(5, ledger.view().charged.structural_visits);
    try std.testing.expectEqual(1, ledger.view().executed.work.analysis_computations);
    try std.testing.expectEqual(0, ledger.view().executed.counters.analysis_misses);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(
        error.TerminalWorkOutcome,
        ctx.getAnalysis(module.op, &descriptor, computeMeteredTyped, cleanupMeteredTyped),
    );
    try std.testing.expectEqual(1, typed_analysis_counter);
}

fn refreshMeteredCounter(_: *PassContext, _: *ir.Operation, value: *anyopaque) !void {
    analysis_counter += 1;
    const counter: *u32 = @ptrCast(@alignCast(value));
    counter.* = analysis_counter;
}

test "U0 analysis refresh charges before replacing a cached value" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, ir.Location.getUnknown());
    const descriptor = AnalysisDescriptor{
        .id = analysisId("u0-metered-analysis"),
        .name = "u0-metered-analysis",
        .work_contract = .{
            .identity = .{ .name = "u0-metered-analysis", .version = 1 },
            .estimate = meteredAnalysisBounds,
        },
    };
    for ([_]u64{ 1, 2 }) |computations| {
        const ledger = try revision.AccountingV1.create(allocator, .{
            .allowance = .{
                .structural_visits = 10,
                .analysis_computations = computations,
                .allocation_capacity = 65536,
            },
            .workspace = 4096,
            .events = 8,
        }, &.{});
        defer ledger.destroy();
        var stats: PassManagerStats = .{};
        var cache = try AnalysisCache.initAccounted(allocator, &stats, ledger, .{}, 4);
        defer cache.deinit();
        var ctx = PassContext.init(module.op, &context, allocator, &cache);
        defer ctx.deinit();
        analysis_counter = 0;
        const first = try ctx.getAnalysis(module.op, &descriptor, computeCounter, cleanupCounter);
        const result = ctx.refreshAnalysis(module.op, &descriptor, refreshMeteredCounter);
        if (computations == 1) {
            try std.testing.expectError(error.WorkExhausted, result);
            try std.testing.expectEqual(1, @as(*u32, @ptrCast(@alignCast(first))).*);
            try std.testing.expectEqual(.exhausted, ledger.view().outcome);
        } else {
            try result;
            const next = try ctx.getAnalysis(
                module.op,
                &descriptor,
                computeCounter,
                cleanupCounter,
            );
            try std.testing.expectEqual(first, next);
            try std.testing.expectEqual(2, @as(*u32, @ptrCast(@alignCast(next))).*);
        }
        try std.testing.expectEqual(computations, analysis_counter);
        try std.testing.expectEqual(computations, stats.analysis_misses);
        try std.testing.expectEqual(2, ledger.view().charged.analysis_computations);
    }
}

const MeteredTypedAnalysis = Analysis(
    u32,
    "u0-metered-typed-analysis",
    &.{},
    computeTypedCounter,
    cleanupTypedCounter,
    .{
        .identity = .{ .name = "u0-metered-typed-analysis", .version = 1 },
        .estimate = meteredAnalysisBounds,
    },
);

test "U0 analysis typed registration carries its normative declaration" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, ir.Location.getUnknown());
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{ .analysis_computations = 0, .allocation_capacity = 65536 },
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var cache = try AnalysisCache.initAccounted(allocator, null, ledger, .{}, 4);
    defer cache.deinit();
    var ctx = PassContext.init(module.op, &context, allocator, &cache);
    defer ctx.deinit();
    typed_analysis_counter = 0;
    try std.testing.expectError(error.WorkExhausted, MeteredTypedAnalysis.get(&ctx, module.op));
    try std.testing.expectEqual(0, typed_analysis_counter);
    try std.testing.expect(!ledger.view().missing_work_contract);
    try std.testing.expectEqualStrings(
        "u0-metered-typed-analysis",
        ledger.view().events[1].identity().name,
    );
}

test "U0 analysis fixed workspace exhaustion retains cleanup and refuses a fresh retry" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const fixed = @import("alloc_fixed");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, ir.Location.getUnknown());
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{
            .structural_visits = 5,
            .analysis_computations = 1,
            .allocation_capacity = 65536,
        },
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var bytes: [4096]u8 align(@alignOf(usize)) = undefined;
    var storage = fixed.Tracked.init(&bytes);
    var cache = try AnalysisCache.initAccounted(
        storage.allocator(),
        null,
        ledger,
        .{ .workspace = &storage.exhausted },
        4,
    );
    defer cache.deinit();
    var ctx = PassContext.init(module.op, &context, storage.allocator(), &cache);
    defer ctx.deinit();
    typed_analysis_counter = 0;
    typed_analysis_cleanup_count = 0;
    try std.testing.expectError(error.WorkExhausted, OversizedTypedAnalysis.get(&ctx, module.op));
    try std.testing.expectEqual(1, typed_analysis_counter);
    try std.testing.expectEqual(0, typed_analysis_cleanup_count);
    try std.testing.expectEqual(0, cache.entries.count());
    try std.testing.expectEqual(.exhausted, ledger.view().outcome);
    try std.testing.expectEqual(1, ledger.view().charged.analysis_computations);
    try std.testing.expectEqual(0, ledger.view().executed.counters.analysis_misses);
    try std.testing.expectError(
        error.TerminalWorkOutcome,
        OversizedTypedAnalysis.get(&ctx, module.op),
    );
    try std.testing.expectEqual(1, typed_analysis_counter);
}

test "U0 analysis cache reserves its declared table before computations" {
    const revision = @import("../../product/revision/root.zig");
    const allocator = std.testing.allocator;
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{ .allocation_capacity = 65536 },
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const result = AnalysisCache.initAccounted(failing.allocator(), null, ledger, .{}, 4);
    if (result) |value| {
        var cache = value;
        cache.deinit();
    } else |_| {}
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(.rejected, ledger.view().outcome);
    try std.testing.expect(ledger.view().charged.allocation_capacity > 0);
    try std.testing.expectEqual(0, ledger.view().executed.work.analysis_computations);
}

const OversizedTypedAnalysis = Analysis(
    u32,
    "u0-oversized-analysis",
    &.{},
    computeOversizedCounter,
    cleanupTypedCounter,
    .{
        .identity = .{ .name = "u0-oversized-analysis", .version = 1 },
        .estimate = oversizedAnalysisBounds,
    },
);

fn computeOversizedCounter(ctx: *PassContext, _: *ir.Operation) !*u32 {
    typed_analysis_counter += 1;
    {
        const scratch = try ctx.allocator.alloc(u8, 4096);
        defer ctx.allocator.free(scratch);
        @memset(scratch, 0);
    }
    const value = try ctx.allocator.create(u32);
    value.* = typed_analysis_counter;
    return value;
}

fn oversizedAnalysisBounds(input: subject.work.Input) !subject.work.Bounds {
    var bounds = try meteredAnalysisBounds(input);
    bounds.work.allocation_capacity = 8192;
    return bounds;
}

test "U0 analysis cache storage bound covers real table allocation and teardown" {
    const revision = @import("../../product/revision/root.zig");
    const allocator = std.testing.allocator;
    for ([_]u32{ 0, 1, 6, 7, 8, 13, 64, 1024, 65536 }) |limit| {
        const bound = try AnalysisCache.storageBound(limit);
        const ledger = try revision.AccountingV1.create(allocator, .{
            .allowance = .{ .allocation_capacity = bound },
            .workspace = bound,
            .events = 8,
        }, &.{});
        defer ledger.destroy();
        var observed = std.testing.FailingAllocator.init(allocator, .{});
        var cache = try AnalysisCache.initAccounted(
            observed.allocator(),
            null,
            ledger,
            .{},
            limit,
        );
        try std.testing.expect(observed.allocated_bytes <= bound);
        try std.testing.expectEqual(@as(usize, if (limit == 0) 0 else 1), observed.allocations);
        try std.testing.expectEqual(0, cache.entries.count());
        try std.testing.expectEqual(bound, ledger.view().charged.allocation_capacity);
        try std.testing.expectEqual(.success, ledger.view().events[0].outcome);
        cache.deinit();
        try std.testing.expectEqual(observed.allocated_bytes, observed.freed_bytes);
    }
    try std.testing.expectError(
        error.WorkOverflow,
        AnalysisCache.storageBound(std.math.maxInt(u32)),
    );
}

test "U0 analysis cache refuses its entry limit before the next computation without table growth" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{
            .structural_visits = 10,
            .analysis_computations = 2,
            .allocation_capacity = 65536,
        },
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var observed = std.testing.FailingAllocator.init(allocator, .{});
    var cache = try AnalysisCache.initAccounted(observed.allocator(), null, ledger, .{}, 1);
    defer cache.deinit();
    const capacity = cache.entries.capacity();
    var ctx = PassContext.init(module.op, &context, observed.allocator(), &cache);
    defer ctx.deinit();
    typed_analysis_counter = 0;
    _ = try MeteredTypedAnalysis.get(&ctx, module.op);
    try std.testing.expectEqual(2, observed.allocations);
    var another = MeteredTypedAnalysis.descriptor;
    another.id = analysisId("another-analysis");
    try std.testing.expectError(
        error.WorkExhausted,
        ctx.getAnalysis(module.op, &another, computeMeteredTyped, cleanupMeteredTyped),
    );
    try std.testing.expectEqual(1, typed_analysis_counter);
    try std.testing.expectEqual(2, observed.allocations);
    try std.testing.expectEqual(capacity, cache.entries.capacity());
    try std.testing.expectEqual(1, cache.entries.count());
    try std.testing.expectEqual(2, ledger.view().charged.analysis_computations);
    try std.testing.expectEqual(1, ledger.view().executed.work.analysis_computations);
    try std.testing.expectEqual(.exhausted, ledger.view().events[2].outcome);
    try std.testing.expectEqual(0, ledger.view().events[2].executed.work.analysis_computations);
}

var metered_pass_runs: u32 = 0;

fn runMeteredPass(ctx: *PassContext) PassResult {
    metered_pass_runs += 1;
    ctx.preserveAllAnalyses();
    return .success;
}

fn meteredPassBounds(_: subject.work.Input) !subject.work.Bounds {
    return .{ .work = .{ .structural_visits = 5 } };
}

test "U0 pass admission refuses before the callback and uses the existing failure finalization" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const identity = revision.record.Version{ .name = "u0-metered-pass", .version = 1 };
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{ .structural_visits = 4, .allocation_capacity = 65536 },
        .workspace = 4096,
        .events = 8,
    }, &.{identity});
    defer ledger.destroy();
    var cache = try AnalysisCache.initAccounted(allocator, null, ledger, .{}, 4);
    defer cache.deinit();
    var manager = PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(.{
        .name = identity.name,
        .description = "bounded pass witness",
        .run_fn = runMeteredPass,
        .work_contract = .{ .identity = identity, .estimate = meteredPassBounds },
    });
    metered_pass_runs = 0;
    try std.testing.expectEqual(
        .failure,
        manager.runWithAnalysisCache(module.op, &context, &cache, .{}),
    );
    try std.testing.expectEqual(0, metered_pass_runs);
    try std.testing.expectEqual(0, manager.stats.pass_runs);
    try std.testing.expectEqual(1, manager.stats.pass_failures);
    try std.testing.expectEqual(.exhausted, ledger.view().outcome);
    try std.testing.expectEqual(5, ledger.view().charged.structural_visits);
    const failure = manager.getLastFailureReproducer() orelse return error.TestExpectedFailure;
    try std.testing.expectEqual(.exhausted, failure.failure_kind.?);
    const charged = ledger.view().charged;
    try std.testing.expectEqual(.failure, manager.runWithAnalysisCache(
        module.op,
        &context,
        &cache,
        .{ .max_threads = 2 },
    ));
    try std.testing.expectEqual(0, metered_pass_runs);
    try std.testing.expectEqual(1, manager.stats.pass_failures);
    try std.testing.expectEqualDeep(charged, ledger.view().charged);
    try std.testing.expectEqual(.exhausted, manager.getLastFailureReproducer().?.failure_kind.?);
}

fn runMeteredAnalysisPass(ctx: *PassContext) PassResult {
    metered_pass_runs += 1;
    _ = MeteredTypedAnalysis.get(ctx, ctx.op) catch return .failure;
    ctx.preserveAllAnalyses();
    return .success;
}

fn runSuppressingAnalysisFailure(ctx: *PassContext) PassResult {
    metered_pass_runs += 1;
    _ = MeteredTypedAnalysis.get(ctx, ctx.op) catch return .success;
    return .success;
}

test "U0 pass accounting executes repeated entries and records one cached analysis computation" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const identity = revision.record.Version{ .name = "u0-metered-pass", .version = 1 };
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{ .structural_visits = 15, .analysis_computations = 1, .allocation_capacity = 65536 },
        .workspace = 4096,
        .events = 8,
    }, &.{ identity, identity });
    defer ledger.destroy();
    var cache = try AnalysisCache.initAccounted(allocator, null, ledger, .{}, 4);
    defer cache.deinit();
    var manager = PassManager.init(allocator);
    defer manager.deinit();
    const entry = Pass{
        .name = identity.name,
        .description = "bounded pass witness",
        .run_fn = runMeteredAnalysisPass,
        .rerun_policy = .skip_if_unchanged,
        .work_contract = .{ .identity = identity, .estimate = meteredPassBounds },
    };
    try manager.addPass(entry);
    try manager.addPass(entry);
    metered_pass_runs = 0;
    typed_analysis_counter = 0;
    try std.testing.expectEqual(.success, manager.runWithAnalysisCache(module.op, &context, &cache, .{}));
    const receipt = ledger.view();
    try std.testing.expectEqual(2, metered_pass_runs);
    try std.testing.expectEqual(1, typed_analysis_counter);
    try std.testing.expectEqual(0, manager.stats.passes_skipped);
    try std.testing.expectEqual(2, receipt.executed.counters.pass_runs);
    try std.testing.expectEqual(1, receipt.executed.counters.analysis_misses);
    try std.testing.expectEqual(1, receipt.executed.counters.analysis_hits);
    try std.testing.expectEqual(15, receipt.charged.structural_visits);
    try std.testing.expectEqual(1, receipt.events[2].parent.?);
    try ledger.producersComplete();
}

test "U0 pass propagates analysis exhaustion even when native code reports success" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const callbacks = [_]*const fn (*PassContext) PassResult{
        runMeteredAnalysisPass, runSuppressingAnalysisFailure,
    };
    for (callbacks) |callback| {
        const identity = revision.record.Version{ .name = "u0-metered-pass", .version = 1 };
        const ledger = try revision.AccountingV1.create(allocator, .{
            .allowance = .{ .structural_visits = 9, .analysis_computations = 1, .allocation_capacity = 65536 },
            .workspace = 4096,
            .events = 8,
        }, &.{identity});
        defer ledger.destroy();
        var cache = try AnalysisCache.initAccounted(allocator, null, ledger, .{}, 4);
        defer cache.deinit();
        var manager = PassManager.init(allocator);
        defer manager.deinit();
        try manager.addPass(.{
            .name = identity.name,
            .description = "bounded pass witness",
            .run_fn = callback,
            .work_contract = .{ .identity = identity, .estimate = meteredPassBounds },
        });
        metered_pass_runs = 0;
        typed_analysis_counter = 0;
        try std.testing.expectEqual(.failure, manager.runWithAnalysisCache(module.op, &context, &cache, .{}));
        try std.testing.expectEqual(1, metered_pass_runs);
        try std.testing.expectEqual(0, typed_analysis_counter);
        try std.testing.expectEqual(1, manager.stats.pass_runs);
        try std.testing.expectEqual(1, manager.stats.pass_failures);
        try std.testing.expectEqual(1, ledger.view().executed.counters.pass_runs);
        try std.testing.expectEqual(.exhausted, ledger.view().events[1].outcome);
        const failure = manager.getLastFailureReproducer() orelse return error.TestExpectedFailure;
        try std.testing.expectEqual(.exhausted, failure.failure_kind.?);
    }
}

test "U0 pass refuses scheduling outside the declared serial job before its callback" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{ .allocation_capacity = 65536 },
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var cache = try AnalysisCache.initAccounted(allocator, null, ledger, .{}, 4);
    defer cache.deinit();
    var manager = PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(.{ .name = "transient", .description = "", .run_fn = runMeteredPass });
    metered_pass_runs = 0;
    try std.testing.expectEqual(.failure, manager.runWithAnalysisCache(
        module.op,
        &context,
        &cache,
        .{ .max_threads = 2 },
    ));
    try std.testing.expectEqual(0, metered_pass_runs);
    try std.testing.expect(ledger.view().missing_work_contract);
    try std.testing.expectEqual(.rejected, ledger.view().outcome);
}

test "U0 pass missing contract records successful and failed physical callbacks without qualification" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const callbacks = [_]*const fn (*PassContext) PassResult{
        runMeteredPass, runMeteredAnalysisPass,
    };
    for (callbacks, 0..) |callback, index| {
        const ledger = try revision.AccountingV1.create(allocator, .{
            .allowance = .{ .allocation_capacity = 65536 },
            .workspace = 4096,
            .events = 8,
        }, &.{});
        defer ledger.destroy();
        var cache = try AnalysisCache.initAccounted(allocator, null, ledger, .{}, 4);
        defer cache.deinit();
        var manager = PassManager.init(allocator);
        defer manager.deinit();
        try manager.addPass(.{ .name = "uncontracted", .description = "", .run_fn = callback });
        const result = manager.runWithAnalysisCache(module.op, &context, &cache, .{});
        try std.testing.expectEqual(if (index == 0) PassResult.success else .failure, result);
        try std.testing.expect(ledger.view().missing_work_contract);
        try std.testing.expectEqual(1, manager.stats.pass_runs);
        try std.testing.expectEqual(1, ledger.view().executed.counters.pass_runs);
        if (index == 0) {
            try std.testing.expectError(error.MissingWorkContract, ledger.producersComplete());
        } else {
            try std.testing.expectEqual(.exhausted, ledger.view().outcome);
            try std.testing.expectError(error.WorkExhausted, ledger.producersComplete());
        }
    }
}

fn runSuppressingContextFailure(ctx: *PassContext) PassResult {
    const payload: [1024]u8 = @splat('x');
    _ = ctx.ir_ctx.getStringAttr(&payload) catch return .success;
    return .success;
}

test "U0 pass caught Context exhaustion stops subsequent callbacks through one finalizer" {
    try checkContextPassFailure(false);
    try checkContextPassFailure(true);
}

fn checkContextPassFailure(already_exhausted: bool) !void {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var limits = ir.Context.Limits.testing;
    limits.attributes.payload_bytes = 128;
    var context = try ir.Context.init(allocator, limits);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const identity = revision.record.Version{ .name = "u0-context-pass", .version = 1 };
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = revision.WorkVector.uniform(65536),
        .workspace = 4096,
        .events = 8,
    }, &.{ identity, identity });
    defer ledger.destroy();
    var cache = try AnalysisCache.initAccounted(
        allocator,
        null,
        ledger,
        .{ .context = &context },
        4,
    );
    defer cache.deinit();
    var manager = PassManager.init(allocator);
    defer manager.deinit();
    const contract = subject.work.Contract{ .identity = identity, .estimate = meteredPassBounds };
    try manager.addPass(.{
        .name = identity.name,
        .description = "caught Context storage failure",
        .run_fn = runSuppressingContextFailure,
        .work_contract = contract,
    });
    try manager.addPass(.{
        .name = identity.name,
        .description = "must not execute after Context exhaustion",
        .run_fn = runMeteredPass,
        .work_contract = contract,
    });
    if (already_exhausted) {
        var ctx = PassContext.init(module.op, &context, allocator, &cache);
        defer ctx.deinit();
        _ = runSuppressingContextFailure(&ctx);
    }
    metered_pass_runs = 0;
    const result = manager.runWithAnalysisCache(module.op, &context, &cache, .{});
    try std.testing.expectEqual(.attribute_payloads, context.exhaustedSegment().?);
    try std.testing.expectEqual(.failure, result);
    try std.testing.expectEqual(0, metered_pass_runs);
    try std.testing.expectEqual(@intFromBool(!already_exhausted), manager.stats.pass_runs);
    try std.testing.expectEqual(.exhausted, ledger.view().outcome);
    if (!already_exhausted) {
        try std.testing.expectEqual(.exhausted, ledger.view().events[1].outcome);
    }
    try std.testing.expectEqual(.exhausted, manager.getLastFailureReproducer().?.failure_kind.?);
}

fn runSuppressingStorageFailure(ctx: *PassContext) PassResult {
    const bytes = ctx.analysis_cache.allocator.alloc(u8, 4096) catch return .success;
    ctx.analysis_cache.allocator.free(bytes);
    return .success;
}

fn computeSuppressingContextFailure(ctx: *PassContext, op: *ir.Operation) !*anyopaque {
    const value = try computeMeteredTyped(ctx, op);
    _ = runSuppressingContextFailure(ctx);
    return value;
}

fn refreshSuppressingContextFailure(ctx: *PassContext, _: *ir.Operation, _: *anyopaque) !void {
    analysis_counter += 1;
    _ = runSuppressingContextFailure(ctx);
}

const ContextFailureMode = enum { compute, hit, refresh_before, refresh_during };

test "U0 analysis refuses setup after Context exhaustion without acquiring cache storage" {
    const revision = @import("../../product/revision/root.zig");
    const allocator = std.testing.allocator;
    var limits = ir.Context.Limits.testing;
    limits.attributes.payload_bytes = 128;
    var context = try ir.Context.init(allocator, limits);
    defer context.deinit(allocator);
    const payload: [1024]u8 = @splat('x');
    try std.testing.expectError(error.OutOfMemory, context.getStringAttr(&payload));
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = revision.WorkVector.uniform(65536),
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const result = AnalysisCache.initAccounted(
        failing.allocator(),
        null,
        ledger,
        .{ .context = &context },
        4,
    );
    if (result) |value| {
        var cache = value;
        cache.deinit();
    } else |_| {}
    try std.testing.expectError(error.WorkExhausted, result);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(.exhausted, ledger.view().outcome);
    try std.testing.expectEqual(0, ledger.view().charged.allocation_capacity);
}

test "U0 analysis caught Context exhaustion refuses computation results hits and refresh" {
    for (std.enums.values(ContextFailureMode)) |mode| try checkContextAnalysisFailure(mode);
}

fn checkContextAnalysisFailure(mode: ContextFailureMode) !void {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const allocator = std.testing.allocator;
    var limits = ir.Context.Limits.testing;
    limits.attributes.payload_bytes = 128;
    var context = try ir.Context.init(allocator, limits);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = revision.WorkVector.uniform(65536),
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var stats: PassManagerStats = .{};
    var cache = try AnalysisCache.initAccounted(
        allocator,
        &stats,
        ledger,
        .{ .context = &context },
        4,
    );
    defer cache.deinit();
    var ctx = PassContext.init(module.op, &context, allocator, &cache);
    defer ctx.deinit();
    typed_analysis_counter = 0;
    typed_analysis_cleanup_count = 0;
    analysis_counter = 0;
    const descriptor = &MeteredTypedAnalysis.descriptor;
    if (mode != .compute) _ = try MeteredTypedAnalysis.get(&ctx, module.op);
    if (mode == .hit or mode == .refresh_before) _ = runSuppressingContextFailure(&ctx);
    switch (mode) {
        .compute, .hit => try std.testing.expectError(error.WorkExhausted, ctx.getAnalysis(
            module.op,
            descriptor,
            computeSuppressingContextFailure,
            cleanupMeteredTyped,
        )),
        .refresh_before, .refresh_during => try std.testing.expectError(
            error.WorkExhausted,
            ctx.refreshAnalysis(module.op, descriptor, refreshSuppressingContextFailure),
        ),
    }
    try std.testing.expectEqual(.attribute_payloads, context.exhaustedSegment().?);
    try std.testing.expectEqual(.exhausted, ledger.view().outcome);
    try std.testing.expectEqual(1, typed_analysis_counter);
    try std.testing.expectEqual(@intFromBool(mode == .compute), typed_analysis_cleanup_count);
    try std.testing.expectEqual(@intFromBool(mode != .compute), cache.entries.count());
    try std.testing.expectEqual(@intFromBool(mode == .refresh_during), analysis_counter);
    try std.testing.expectEqual(0, stats.analysis_hits);
    try std.testing.expectEqual(@intFromBool(mode != .compute), stats.analysis_misses);
    try std.testing.expectError(
        error.TerminalWorkOutcome,
        MeteredTypedAnalysis.get(&ctx, module.op),
    );
    try std.testing.expectEqual(1, typed_analysis_counter);
}

test "U0 pass caught workspace exhaustion stops subsequent callbacks through one finalizer" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const fixed = @import("alloc_fixed");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    for ([_]bool{ false, true }) |already_exhausted| {
        const identity = revision.record.Version{ .name = "u0-storage-pass", .version = 1 };
        const ledger = try revision.AccountingV1.create(allocator, .{
            .allowance = revision.WorkVector.uniform(65536),
            .workspace = 4096,
            .events = 8,
        }, &.{ identity, identity });
        defer ledger.destroy();
        var bytes: [4096]u8 align(@alignOf(usize)) = undefined;
        var storage = fixed.Tracked.init(&bytes);
        var cache = try AnalysisCache.initAccounted(
            storage.allocator(),
            null,
            ledger,
            .{ .workspace = &storage.exhausted },
            4,
        );
        defer cache.deinit();
        var manager = PassManager.init(allocator);
        defer manager.deinit();
        const contract = subject.work.Contract{ .identity = identity, .estimate = meteredPassBounds };
        try manager.addPass(.{
            .name = identity.name,
            .description = "caught fixed storage failure",
            .run_fn = runSuppressingStorageFailure,
            .work_contract = contract,
        });
        try manager.addPass(.{
            .name = identity.name,
            .description = "must not execute after exhaustion",
            .run_fn = runMeteredPass,
            .work_contract = contract,
        });
        if (already_exhausted) {
            try std.testing.expectError(error.OutOfMemory, storage.allocator().alloc(u8, 4096));
        }
        metered_pass_runs = 0;
        try std.testing.expectEqual(
            .failure,
            manager.runWithAnalysisCache(module.op, &context, &cache, .{}),
        );
        try std.testing.expect(storage.exhausted);
        try std.testing.expectEqual(0, metered_pass_runs);
        try std.testing.expectEqual(@intFromBool(!already_exhausted), manager.stats.pass_runs);
        try std.testing.expectEqual(1, manager.stats.pass_failures);
        try std.testing.expectEqual(.exhausted, ledger.view().outcome);
        try std.testing.expectEqual(.exhausted, manager.getLastFailureReproducer().?.failure_kind.?);
        if (!already_exhausted) {
            try std.testing.expectEqual(.exhausted, ledger.view().events[1].outcome);
        }
    }
}

fn computeSuppressingStorageFailure(ctx: *PassContext, op: *ir.Operation) !*anyopaque {
    const value = try computeMeteredTyped(ctx, op);
    _ = runSuppressingStorageFailure(ctx);
    return value;
}

fn refreshSuppressingStorageFailure(ctx: *PassContext, _: *ir.Operation, _: *anyopaque) !void {
    analysis_counter += 1;
    _ = runSuppressingStorageFailure(ctx);
}

test "U0 analysis caught workspace exhaustion refuses computation results hits and refresh" {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const fixed = @import("alloc_fixed");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const Mode = enum { compute, hit, refresh_before, refresh_during };
    for (std.enums.values(Mode)) |mode| {
        const ledger = try revision.AccountingV1.create(allocator, .{
            .allowance = revision.WorkVector.uniform(65536),
            .workspace = 4096,
            .events = 8,
        }, &.{});
        defer ledger.destroy();
        var bytes: [4096]u8 align(@alignOf(usize)) = undefined;
        var storage = fixed.Tracked.init(&bytes);
        var stats: PassManagerStats = .{};
        var cache = try AnalysisCache.initAccounted(
            storage.allocator(),
            &stats,
            ledger,
            .{ .workspace = &storage.exhausted },
            4,
        );
        defer cache.deinit();
        var ctx = PassContext.init(module.op, &context, storage.allocator(), &cache);
        defer ctx.deinit();
        typed_analysis_counter = 0;
        typed_analysis_cleanup_count = 0;
        analysis_counter = 0;
        const descriptor = &MeteredTypedAnalysis.descriptor;
        if (mode != .compute) _ = try MeteredTypedAnalysis.get(&ctx, module.op);
        if (mode == .hit or mode == .refresh_before) _ = runSuppressingStorageFailure(&ctx);
        switch (mode) {
            .compute, .hit => try std.testing.expectError(error.WorkExhausted, ctx.getAnalysis(
                module.op,
                descriptor,
                computeSuppressingStorageFailure,
                cleanupMeteredTyped,
            )),
            .refresh_before, .refresh_during => try std.testing.expectError(
                error.WorkExhausted,
                ctx.refreshAnalysis(module.op, descriptor, refreshSuppressingStorageFailure),
            ),
        }
        try std.testing.expect(storage.exhausted);
        try std.testing.expectEqual(.exhausted, ledger.view().outcome);
        try std.testing.expectEqual(1, typed_analysis_counter);
        try std.testing.expectEqual(@intFromBool(mode == .compute), typed_analysis_cleanup_count);
        try std.testing.expectEqual(@intFromBool(mode != .compute), cache.entries.count());
        try std.testing.expectEqual(@intFromBool(mode == .refresh_during), analysis_counter);
        try std.testing.expectEqual(0, stats.analysis_hits);
        try std.testing.expectEqual(@intFromBool(mode != .compute), stats.analysis_misses);
        try std.testing.expectError(
            error.TerminalWorkOutcome,
            MeteredTypedAnalysis.get(&ctx, module.op),
        );
        try std.testing.expectEqual(1, typed_analysis_counter);
    }
}

test "U0 analysis host OOM before workspace allocation stays rejected" {
    const revision = @import("../../product/revision/root.zig");
    const fixed = @import("alloc_fixed");
    const allocator = std.testing.allocator;
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .{ .allocation_capacity = 65536 },
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var bytes: [4096]u8 align(@alignOf(usize)) = undefined;
    var storage = fixed.Tracked.init(&bytes);
    var failing = std.testing.FailingAllocator.init(storage.allocator(), .{ .fail_index = 0 });
    const result = AnalysisCache.initAccounted(
        failing.allocator(),
        null,
        ledger,
        .{ .workspace = &storage.exhausted },
        4,
    );
    if (result) |value| {
        var cache = value;
        cache.deinit();
    } else |_| {}
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!storage.exhausted);
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(.rejected, ledger.view().outcome);
    try std.testing.expect(ledger.view().charged.allocation_capacity > 0);
    try std.testing.expectEqual(0, ledger.view().executed.work.analysis_computations);
}

fn allocateWorkerByte(ctx: *PassContext) !void {
    analysis_counter += 1;
    const allocator = ctx.workerAllocator();
    const bytes = try allocator.alloc(u8, 1);
    defer allocator.free(bytes);
}

fn computeWithWorkerAllocation(ctx: *PassContext, op: *ir.Operation) !*anyopaque {
    try allocateWorkerByte(ctx);
    return computeMeteredTyped(ctx, op);
}

fn refreshWithWorkerAllocation(ctx: *PassContext, _: *ir.Operation, value: *anyopaque) !void {
    try allocateWorkerByte(ctx);
    const typed: *u32 = @ptrCast(@alignCast(value));
    typed.* += 1;
}

test "U0 analysis separate worker host OOM rejects computation without retry" {
    try checkWorkerAllocationFailure(false, false);
}

test "U0 analysis separate worker host OOM rejects refresh without retry" {
    try checkWorkerAllocationFailure(true, false);
}

test "U0 analysis caught workspace exhaustion dominates a later compute error" {
    try checkWorkerAllocationFailure(false, true);
}

test "U0 analysis caught workspace exhaustion dominates a later refresh error" {
    try checkWorkerAllocationFailure(true, true);
}

fn computeAfterWorkspaceExhaustion(ctx: *PassContext, _: *ir.Operation) !*anyopaque {
    analysis_counter += 1;
    _ = runSuppressingStorageFailure(ctx);
    return error.UnsupportedOperation;
}

fn refreshAfterWorkspaceExhaustion(ctx: *PassContext, _: *ir.Operation, _: *anyopaque) !void {
    analysis_counter += 1;
    _ = runSuppressingStorageFailure(ctx);
    return error.UnsupportedOperation;
}

fn checkWorkerAllocationFailure(refresh: bool, exhaust_workspace: bool) !void {
    const revision = @import("../../product/revision/root.zig");
    const fixture = @import("../../dialects/fixture/root.zig");
    const fixed = @import("alloc_fixed");
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const module = try fixture.TestDialect.ModuleOp.create(&context, .unknown);
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = revision.WorkVector.uniform(65536),
        .workspace = 4096,
        .events = 8,
    }, &.{});
    defer ledger.destroy();
    var bytes: [4096]u8 align(@alignOf(usize)) = undefined;
    var storage = fixed.Tracked.init(&bytes);
    var stats: PassManagerStats = .{};
    var cache = try AnalysisCache.initAccounted(
        storage.allocator(),
        &stats,
        ledger,
        .{ .workspace = &storage.exhausted },
        4,
    );
    defer cache.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var ctx = PassContext.initWithOptions(module.op, &context, storage.allocator(), &cache, .{
        .worker_allocator = failing.allocator(),
    });
    defer ctx.deinit();
    typed_analysis_counter = 0;
    analysis_counter = 0;
    const value = if (refresh) try MeteredTypedAnalysis.get(&ctx, module.op) else null;
    const descriptor = &MeteredTypedAnalysis.descriptor;
    const expected = if (exhaust_workspace) error.WorkExhausted else error.OutOfMemory;
    if (refresh) {
        try std.testing.expectError(expected, ctx.refreshAnalysis(
            module.op,
            descriptor,
            if (exhaust_workspace) refreshAfterWorkspaceExhaustion else refreshWithWorkerAllocation,
        ));
        try std.testing.expectEqual(@as(u32, 1), value.?.*);
    } else {
        try std.testing.expectError(expected, ctx.getAnalysis(
            module.op,
            descriptor,
            if (exhaust_workspace) computeAfterWorkspaceExhaustion else computeWithWorkerAllocation,
            cleanupMeteredTyped,
        ));
    }
    try std.testing.expectEqual(!exhaust_workspace, failing.has_induced_failure);
    try std.testing.expectEqual(exhaust_workspace, storage.exhausted);
    try std.testing.expectEqual(
        if (exhaust_workspace) @as(@TypeOf(ledger.view().outcome), .exhausted) else .rejected,
        ledger.view().outcome,
    );
    try std.testing.expectEqual(@intFromBool(refresh), cache.entries.count());
    try std.testing.expectEqual(@intFromBool(refresh), stats.analysis_misses);
    try std.testing.expectEqual(
        1 + @as(u64, @intFromBool(refresh)),
        ledger.view().charged.analysis_computations,
    );
    try std.testing.expectError(
        error.TerminalWorkOutcome,
        MeteredTypedAnalysis.get(&ctx, module.op),
    );
    try std.testing.expectEqual(1, analysis_counter);
}

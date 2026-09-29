const std = @import("std");
const choir = @import("../../../root.zig");

const ir = choir.ir;
const rewrite = ir.rewrite;
const passes = choir.passes;
const dialects = choir.dialects;
const backends = choir.backends;
const gpu = @import("../../../dialects/gpu/root.zig");
const spirv = @import("dialect.zig");
const spirv_emit = @import("emitter/root.zig").emit;

const Pass = passes.Pass;
const PassContext = passes.PassContext;
const PassResult = passes.PassResult;

const ConversionTarget = passes.ConversionTarget;
const RewritePatternSet = rewrite.RewritePatternSet;
const RewritePattern = rewrite.RewritePattern;
const PatternRewriter = rewrite.PatternRewriter;

const ArithDialect = dialects.ArithDialect;
const GpuDialect = gpu.GpuDialect;
const MemrefDialect = dialects.MemrefDialect;
const SpirvDialect = spirv.SpirvDialect;
const Dimension = gpu.Dimension;
const Scope = gpu.Scope;

pub const gpu_to_spirv_pass_name = "gpu-to-spirv";
pub const gpu_to_spirv_pass_description = "Lower GPU + arith ops to SPIR-V dialect";

fn conversionPatternSpec(root_op_name: []const u8) rewrite.RewritePatternSpec {
    return .{
        .name = root_op_name,
        .root_op_name = root_op_name,
    };
}

pub const illegal_ops = [_][]const u8{
    GpuDialect.ThreadIdxOp.operation_name,
    GpuDialect.BlockIdxOp.operation_name,
    GpuDialect.BlockDimOp.operation_name,
    GpuDialect.GridDimOp.operation_name,
    GpuDialect.GlobalIdxOp.operation_name,
    GpuDialect.BarrierOp.operation_name,
    GpuDialect.SyncWarpOp.operation_name,
    GpuDialect.ActiveMaskOp.operation_name,
    GpuDialect.AllSyncOp.operation_name,
    GpuDialect.AnySyncOp.operation_name,
    GpuDialect.BallotSyncOp.operation_name,
    GpuDialect.ShflSyncOp.operation_name,
    GpuDialect.WarpReduceOp.operation_name,
    GpuDialect.WarpScanOp.operation_name,
    ArithDialect.ConstantOp.operation_name,
    ArithDialect.AddOp.operation_name,
    ArithDialect.SubOp.operation_name,
    ArithDialect.MulOp.operation_name,
    ArithDialect.DivOp.operation_name,
};

pub const legal_dialects = [_][]const u8{
    dialects.BuiltinDialect.name,
    dialects.FuncDialect.name,
    dialects.ScfDialect.name,
    ArithDialect.name,
    GpuDialect.name,
    MemrefDialect.name,
    SpirvDialect.name,
};

pub const conversion_pattern_entries = [_]backends.ConversionPatternEntry{
    .{ .spec = conversionPatternSpec(GpuDialect.ThreadIdxOp.operation_name), .rewrite = rewriteThreadIdx },
    .{ .spec = conversionPatternSpec(GpuDialect.BlockIdxOp.operation_name), .rewrite = rewriteBlockIdx },
    .{ .spec = conversionPatternSpec(GpuDialect.BlockDimOp.operation_name), .rewrite = rewriteBlockDim },
    .{ .spec = conversionPatternSpec(GpuDialect.GridDimOp.operation_name), .rewrite = rewriteGridDim },
    .{ .spec = conversionPatternSpec(GpuDialect.GlobalIdxOp.operation_name), .rewrite = rewriteGlobalIdx },
    .{ .spec = conversionPatternSpec(GpuDialect.BarrierOp.operation_name), .rewrite = rewriteBarrier },
    .{ .spec = conversionPatternSpec(GpuDialect.SyncWarpOp.operation_name), .rewrite = rewriteSyncWarp },
    .{ .spec = conversionPatternSpec(GpuDialect.ActiveMaskOp.operation_name), .rewrite = rewriteActiveMask },
    .{ .spec = conversionPatternSpec(GpuDialect.AllSyncOp.operation_name), .rewrite = rewriteAllSync },
    .{ .spec = conversionPatternSpec(GpuDialect.AnySyncOp.operation_name), .rewrite = rewriteAnySync },
    .{ .spec = conversionPatternSpec(GpuDialect.BallotSyncOp.operation_name), .rewrite = rewriteBallotSync },
    .{ .spec = conversionPatternSpec(GpuDialect.ShflSyncOp.operation_name), .rewrite = rewriteShflSync },
    .{ .spec = conversionPatternSpec(GpuDialect.WarpReduceOp.operation_name), .rewrite = rewriteWarpReduce },
    .{ .spec = conversionPatternSpec(GpuDialect.WarpScanOp.operation_name), .rewrite = rewriteWarpScan },
    .{ .spec = conversionPatternSpec(ArithDialect.ConstantOp.operation_name), .rewrite = rewriteArithConstant },
    .{ .spec = conversionPatternSpec(ArithDialect.AddOp.operation_name), .rewrite = rewriteArithAdd },
    .{ .spec = conversionPatternSpec(ArithDialect.SubOp.operation_name), .rewrite = rewriteArithSub },
    .{ .spec = conversionPatternSpec(ArithDialect.MulOp.operation_name), .rewrite = rewriteArithMul },
    .{ .spec = conversionPatternSpec(ArithDialect.DivOp.operation_name), .rewrite = rewriteArithDiv },
};

fn conversionPatternSpecs() [conversion_pattern_entries.len]rewrite.RewritePatternSpec {
    comptime {
        var specs: [conversion_pattern_entries.len]rewrite.RewritePatternSpec = undefined;
        for (conversion_pattern_entries, 0..) |entry, index| {
            specs[index] = entry.spec;
        }
        return specs;
    }
}

pub const conversion_patterns = conversionPatternSpecs();

pub const target_spec = backends.TargetSpec{
    .name = "spirv",
    .description = gpu_to_spirv_pass_description,
    .target_dialect_name = SpirvDialect.name,
    .legality = .{
        .legal_dialects = legal_dialects[0..],
        .illegal_ops = illegal_ops[0..],
    },
    .conversion_patterns = conversion_patterns[0..],
    .pass_name = gpu_to_spirv_pass_name,
    .pass_description = gpu_to_spirv_pass_description,
};

pub fn createGpuToSpirvPass() Pass {
    return .{
        .name = gpu_to_spirv_pass_name,
        .description = gpu_to_spirv_pass_description,
        .run_fn = runGpuToSpirv,
        .mutation_scope = .isolated,
        .dependent_dialects = passes.dialectDependencies(&.{"spirv"}),
    };
}

pub const pass_registration = passes.PassRegistration{
    .name = gpu_to_spirv_pass_name,
    .description = gpu_to_spirv_pass_description,
    .pass = createGpuToSpirvPass(),
};

fn runGpuToSpirv(ctx: *PassContext) PassResult {
    ir.dialects.loadDialectSpec(ctx.ir_ctx, SpirvDialect.spec) catch return .failure;

    var target = ConversionTarget.init(ctx.allocator);
    defer target.deinit();
    target_spec.applyLegality(&target) catch return .failure;

    const had_illegal_ops = containsIllegalOps(ctx.op, &target);

    var patterns = RewritePatternSet.init(ctx.allocator);
    defer patterns.deinit();

    for (conversion_pattern_entries) |entry| {
        patterns.add(RewritePattern.init(entry.spec, entry.rewrite)) catch return .failure;
    }

    const result = passes.conversion.applyFullConversion(ctx.allocator, ctx.ir_ctx, ctx.op, &target, &patterns);
    if (result == .failure) return .failure;

    if (had_illegal_ops) ctx.markModified();
    return .success;
}

fn containsIllegalOps(op: *ir.Operation, target: *const ConversionTarget) bool {
    if (target.isIllegal(op)) return true;
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |child| {
                if (containsIllegalOps(child, target)) return true;
                current = child.next_op;
            }
        }
    }
    return false;
}

fn getDimensionAttr(op: *const ir.Operation) ?Dimension {
    const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "dim") orelse return null;
    return Dimension.fromString(dialect_attr.payload);
}

fn getScopeAttr(op: *const ir.Operation) ?Scope {
    const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "scope") orelse return null;
    return Scope.fromString(dialect_attr.payload);
}

fn rewriteThreadIdx(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteGpuIndex(op, rewriter, SpirvDialect.LocalInvocationIdOp.operation_name);
}

fn rewriteBlockIdx(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteGpuIndex(op, rewriter, SpirvDialect.WorkgroupIdOp.operation_name);
}

fn rewriteBlockDim(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteGpuIndex(op, rewriter, SpirvDialect.WorkgroupSizeOp.operation_name);
}

fn rewriteGridDim(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteGpuIndex(op, rewriter, SpirvDialect.NumWorkgroupsOp.operation_name);
}

fn rewriteGlobalIdx(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteGpuIndex(op, rewriter, SpirvDialect.GlobalInvocationIdOp.operation_name);
}

fn rewriteGpuIndex(
    op: *ir.Operation,
    rewriter: *PatternRewriter,
    target_name: []const u8,
) rewrite.PatternResult {
    const dim = getDimensionAttr(op) orelse return .failure;
    const result = op.getResult(0) orelse return .failure;

    var state = ir.Operation.State.init(target_name, op.location);
    state.addTypes(&.{result.type});
    const dim_attr = rewriter.ir_ctx.getDialectAttr("spirv.dim", dim.toString()) catch return .failure;
    state.addAttributes(&.{.{ .name = "dim", .value = dim_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteBarrier(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const scope = getScopeAttr(op) orelse return .failure;
    var state = ir.Operation.State.init(SpirvDialect.BarrierOp.operation_name, op.location);
    const scope_attr = rewriter.ir_ctx.getDialectAttr("spirv.scope", scope.toString()) catch return .failure;
    state.addAttributes(&.{.{ .name = "scope", .value = scope_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteSyncWarp(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const sync = GpuDialect.SyncWarpOp{ .op = op };
    var state = ir.Operation.State.init(SpirvDialect.SyncWarpOp.operation_name, op.location);
    state.addOperands(&.{sync.getMask()});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteActiveMask(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(SpirvDialect.ActiveMaskOp.operation_name, op.location);
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteAllSync(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const all = GpuDialect.AllSyncOp{ .op = op };
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(SpirvDialect.AllSyncOp.operation_name, op.location);
    state.addOperands(&.{ all.getMask(), all.getPredicate() });
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteAnySync(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const any = GpuDialect.AnySyncOp{ .op = op };
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(SpirvDialect.AnySyncOp.operation_name, op.location);
    state.addOperands(&.{ any.getMask(), any.getPredicate() });
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteBallotSync(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const ballot = GpuDialect.BallotSyncOp{ .op = op };
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(SpirvDialect.BallotSyncOp.operation_name, op.location);
    state.addOperands(&.{ ballot.getMask(), ballot.getPredicate() });
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteShflSync(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const shfl = GpuDialect.ShflSyncOp{ .op = op };
    const mode = shfl.getMode() orelse return .failure;
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(SpirvDialect.ShflSyncOp.operation_name, op.location);
    state.addOperands(&.{ shfl.getMask(), shfl.getSrc(), shfl.getLaneOrDelta() });
    state.addTypes(&.{result.type});
    const mode_attr = rewriter.ir_ctx.getDialectAttr("spirv.shuffle_mode", mode.toString()) catch return .failure;
    state.addAttributes(&.{.{ .name = "mode", .value = mode_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteWarpReduce(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const reduce = GpuDialect.WarpReduceOp{ .op = op };
    const kind = reduce.getOpKind() orelse return .failure;
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(SpirvDialect.WarpReduceOp.operation_name, op.location);
    state.addOperands(&.{ reduce.getMask(), reduce.getValue() });
    state.addTypes(&.{result.type});
    const op_attr = rewriter.ir_ctx.getDialectAttr("spirv.warp_op", kind.toString()) catch return .failure;
    state.addAttributes(&.{.{ .name = "op", .value = op_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteWarpScan(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const scan = GpuDialect.WarpScanOp{ .op = op };
    const kind = scan.getOpKind() orelse return .failure;
    const inclusive = scan.isInclusive();
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(SpirvDialect.WarpScanOp.operation_name, op.location);
    state.addOperands(&.{ scan.getMask(), scan.getValue() });
    state.addTypes(&.{result.type});
    const op_attr = rewriter.ir_ctx.getDialectAttr("spirv.warp_op", kind.toString()) catch return .failure;
    const inclusive_attr = rewriter.ir_ctx.getBoolAttr(inclusive) catch return .failure;
    state.addAttributes(&.{
        .{ .name = "op", .value = op_attr },
        .{ .name = "inclusive", .value = inclusive_attr },
    });
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

const ScalarFlavor = enum { float, signed, unsigned };

fn classifyScalar(ty: ir.Type) ?ScalarFlavor {
    const name = ty.getDialectTypeName() orelse return null;
    const kind = dialects.arith.scalarKindFromTypeName(name) orelse return null;
    return switch (kind) {
        .f16, .f32, .f64 => .float,
        .u8, .u16, .u32, .u64, .index => .unsigned,
        .i8, .i16, .i32, .i64 => .signed,
        .bool, .bf16 => null,
    };
}

const BinaryKind = enum { add, sub, mul, div };

fn rewriteArithConstant(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const result = op.getResult(0) orelse return .failure;
    const constant = ArithDialect.ConstantOp{ .op = op };

    if (constant.getIntValue()) |int_value| {
        var state = ir.Operation.State.init(SpirvDialect.ConstantOp.operation_name, op.location);
        state.addTypes(&.{result.type});
        const value_attr = rewriter.ir_ctx.getI64Attr(int_value) catch return .failure;
        state.addAttributes(&.{.{ .name = "value", .value = value_attr }});
        _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
        return .success;
    }

    if (constant.getFloatValue()) |float_value| {
        var state = ir.Operation.State.init(SpirvDialect.ConstantOp.operation_name, op.location);
        state.addTypes(&.{result.type});
        const value_attr = rewriter.ir_ctx.getF64Attr(float_value) catch return .failure;
        state.addAttributes(&.{.{ .name = "value", .value = value_attr }});
        _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
        return .success;
    }

    if (op.getAttrAs(ir.Attribute.BoolAttr, "value")) |bool_attr| {
        var state = ir.Operation.State.init(SpirvDialect.ConstantOp.operation_name, op.location);
        state.addTypes(&.{result.type});
        const value_attr = rewriter.ir_ctx.getBoolAttr(bool_attr.getValue()) catch return .failure;
        state.addAttributes(&.{.{ .name = "value", .value = value_attr }});
        _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
        return .success;
    }

    return .failure;
}

fn rewriteArithAdd(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteArithBinary(op, rewriter, .add);
}

fn rewriteArithSub(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteArithBinary(op, rewriter, .sub);
}

fn rewriteArithMul(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteArithBinary(op, rewriter, .mul);
}

fn rewriteArithDiv(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteArithBinary(op, rewriter, .div);
}

fn rewriteArithBinary(
    op: *ir.Operation,
    rewriter: *PatternRewriter,
    kind: BinaryKind,
) rewrite.PatternResult {
    if (op.operands.items.len != 2) return .failure;
    const lhs = op.operands.items[0].value;
    const rhs = op.operands.items[1].value;
    const result = op.getResult(0) orelse return .failure;
    const flavor = classifyScalar(result.type) orelse return .failure;

    const target_name = switch (kind) {
        .add => if (flavor == .float) SpirvDialect.FAddOp.operation_name else SpirvDialect.IAddOp.operation_name,
        .sub => if (flavor == .float) SpirvDialect.FSubOp.operation_name else SpirvDialect.ISubOp.operation_name,
        .mul => if (flavor == .float) SpirvDialect.FMulOp.operation_name else SpirvDialect.IMulOp.operation_name,
        .div => switch (flavor) {
            .float => SpirvDialect.FDivOp.operation_name,
            .signed => SpirvDialect.SDivOp.operation_name,
            .unsigned => SpirvDialect.UDivOp.operation_name,
        },
    };

    var state = ir.Operation.State.init(target_name, op.location);
    state.addOperands(&.{ lhs, rhs });
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

test "spirv target spec publishes legality and conversion roots" {
    const testing = std.testing;

    try testing.expectEqualStrings("spirv", target_spec.name);
    try testing.expectEqualStrings(SpirvDialect.name, target_spec.target_dialect_name);
    try testing.expectEqualStrings(gpu_to_spirv_pass_name, target_spec.pass_name);
    try testing.expectEqual(illegal_ops.len, target_spec.conversionPatternRootCount());
    try testing.expect(target_spec.legalizesDialect(SpirvDialect.name));
    try testing.expect(target_spec.marksIllegalOp(GpuDialect.ThreadIdxOp.operation_name));
    try testing.expect(target_spec.marksIllegalOp(ArithDialect.AddOp.operation_name));
    try testing.expect(target_spec.hasConversionPatternRoot(GpuDialect.ThreadIdxOp.operation_name));
    try testing.expect(target_spec.hasConversionPatternRoot(ArithDialect.DivOp.operation_name));

    var target = ConversionTarget.init(testing.allocator);
    defer target.deinit();
    try target_spec.applyLegality(&target);
    try testing.expect(target.legal_dialects.contains(SpirvDialect.name));
    try testing.expect(target.illegal_ops.contains(GpuDialect.ThreadIdxOp.operation_name));
}

test "gpu to spirv conversion rewrites gpu + arith ops" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try dialects.FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    const tid = try GpuDialect.ThreadIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(tid.op);

    const index_type = try ArithDialect.getIndexType(&ctx);
    const one = try ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 1);
    try entry.addOperation(one.op);

    const add = try ArithDialect.AddOp.create(&ctx, loc, tid.getResult(), one.getResult());
    try entry.addOperation(add.op);

    const barrier = try GpuDialect.BarrierOp.create(&ctx, loc, .block);
    try entry.addOperation(barrier.op);

    const ret = try dialects.FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var analysis_cache = passes.AnalysisCache.init(allocator, null);
    defer analysis_cache.deinit();
    var pass_ctx = PassContext.init(module.op, &ctx, allocator, &analysis_cache);
    defer pass_ctx.deinit();

    const pass = createGpuToSpirvPass();
    try testing.expectEqual(PassResult.success, pass.run(&pass_ctx));

    var saw_spirv_index = false;
    var saw_spirv_add = false;
    var saw_spirv_const = false;
    var saw_spirv_barrier = false;

    var op_iter = entry.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (std.mem.eql(u8, op.name.name, SpirvDialect.LocalInvocationIdOp.operation_name)) {
            saw_spirv_index = true;
        }
        if (std.mem.eql(u8, op.name.name, SpirvDialect.IAddOp.operation_name)) {
            saw_spirv_add = true;
        }
        if (std.mem.eql(u8, op.name.name, SpirvDialect.ConstantOp.operation_name)) {
            saw_spirv_const = true;
        }
        if (std.mem.eql(u8, op.name.name, SpirvDialect.BarrierOp.operation_name)) {
            saw_spirv_barrier = true;
        }
        op_iter = op.next_op;
    }

    try testing.expect(saw_spirv_index);
    try testing.expect(saw_spirv_add);
    try testing.expect(saw_spirv_const);
    try testing.expect(saw_spirv_barrier);
}

test "spirv backend emits after gpu-to-spirv conversion" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const module_block = module.getBodyBlock();

    var func = try dialects.FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{});
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    const tid = try GpuDialect.ThreadIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(tid.op);

    const index_type = try ArithDialect.getIndexType(&ctx);
    const one = try ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 1);
    try entry.addOperation(one.op);

    const add = try ArithDialect.AddOp.create(&ctx, loc, tid.getResult(), one.getResult());
    try entry.addOperation(add.op);

    const ret = try dialects.FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var analysis_cache = passes.AnalysisCache.init(allocator, null);
    defer analysis_cache.deinit();
    var pass_ctx = PassContext.init(module.op, &ctx, allocator, &analysis_cache);
    defer pass_ctx.deinit();

    const pass = createGpuToSpirvPass();
    try testing.expectEqual(PassResult.success, pass.run(&pass_ctx));

    var emitter = spirv_emit.Emitter.init(allocator);
    defer emitter.deinit();

    const bytes = try emitter.emitModuleBytes(module.op);
    defer allocator.free(bytes);
    try testing.expect(bytes.len > 0);
}

test "spirv conversion rejects unknown target ops" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const unknown = try ctx.createOperation(ir.Operation.State.init("external.unknown", loc));
    try module.getBodyBlock().addOperation(unknown);

    var analysis_cache = passes.AnalysisCache.init(allocator, null);
    defer analysis_cache.deinit();
    var pass_ctx = PassContext.init(module.op, &ctx, allocator, &analysis_cache);
    defer pass_ctx.deinit();

    const pass = createGpuToSpirvPass();
    try testing.expectEqual(PassResult.failure, pass.run(&pass_ctx));
}

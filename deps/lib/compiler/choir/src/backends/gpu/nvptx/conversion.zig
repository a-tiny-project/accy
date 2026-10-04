const std = @import("std");
const choir = @import("../../../root.zig");

const ir = choir.ir;
const rewrite = ir.rewrite;
const passes = choir.passes;
const dialects = choir.dialects;
const backends = choir.backends;
const gpu = @import("../../../dialects/gpu/root.zig");
const nvptx = @import("dialect.zig");

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
const MemrefAddressSpace = dialects.AddressSpace;
const NvptxDialect = nvptx.NvptxDialect;
const Dimension = gpu.Dimension;
const Scope = gpu.Scope;

pub const gpu_to_nvptx_pass_name = "gpu-to-nvptx";
pub const gpu_to_nvptx_pass_description = "Lower GPU + memref ops to NVPTX dialect";

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
    GpuDialect.LaneIdOp.operation_name,
    GpuDialect.WarpIdOp.operation_name,
    GpuDialect.BarrierOp.operation_name,
    GpuDialect.SyncWarpOp.operation_name,
    GpuDialect.ActiveMaskOp.operation_name,
    GpuDialect.AllSyncOp.operation_name,
    GpuDialect.AnySyncOp.operation_name,
    GpuDialect.BallotSyncOp.operation_name,
    GpuDialect.ShflSyncOp.operation_name,
    GpuDialect.WarpReduceOp.operation_name,
    GpuDialect.WarpScanOp.operation_name,
    GpuDialect.MmaSyncOp.operation_name,
    GpuDialect.FenceOp.operation_name,
    GpuDialect.CpAsyncSharedOp.operation_name,
    GpuDialect.CpAsyncCommitOp.operation_name,
    GpuDialect.CpAsyncWaitOp.operation_name,
    MemrefDialect.LoadOp.operation_name,
    MemrefDialect.StoreOp.operation_name,
    MemrefDialect.AtomicRmwOp.operation_name,
    MemrefDialect.AtomicCasOp.operation_name,
};

pub const legal_dialects = [_][]const u8{
    dialects.BuiltinDialect.name,
    dialects.FuncDialect.name,
    dialects.ScfDialect.name,
    ArithDialect.name,
    GpuDialect.name,
    MemrefDialect.name,
    NvptxDialect.name,
};

pub const conversion_pattern_entries = [_]backends.ConversionPatternEntry{
    .{ .spec = conversionPatternSpec(GpuDialect.ThreadIdxOp.operation_name), .rewrite = rewriteThreadIdx },
    .{ .spec = conversionPatternSpec(GpuDialect.BlockIdxOp.operation_name), .rewrite = rewriteBlockIdx },
    .{ .spec = conversionPatternSpec(GpuDialect.BlockDimOp.operation_name), .rewrite = rewriteBlockDim },
    .{ .spec = conversionPatternSpec(GpuDialect.GridDimOp.operation_name), .rewrite = rewriteGridDim },
    .{ .spec = conversionPatternSpec(GpuDialect.GlobalIdxOp.operation_name), .rewrite = rewriteGlobalIdx },
    .{ .spec = conversionPatternSpec(GpuDialect.LaneIdOp.operation_name), .rewrite = rewriteLaneId },
    .{ .spec = conversionPatternSpec(GpuDialect.WarpIdOp.operation_name), .rewrite = rewriteWarpId },
    .{ .spec = conversionPatternSpec(GpuDialect.BarrierOp.operation_name), .rewrite = rewriteBarrier },
    .{ .spec = conversionPatternSpec(GpuDialect.SyncWarpOp.operation_name), .rewrite = rewriteSyncWarp },
    .{ .spec = conversionPatternSpec(GpuDialect.ActiveMaskOp.operation_name), .rewrite = rewriteActiveMask },
    .{ .spec = conversionPatternSpec(GpuDialect.AllSyncOp.operation_name), .rewrite = rewriteAllSync },
    .{ .spec = conversionPatternSpec(GpuDialect.AnySyncOp.operation_name), .rewrite = rewriteAnySync },
    .{ .spec = conversionPatternSpec(GpuDialect.BallotSyncOp.operation_name), .rewrite = rewriteBallotSync },
    .{ .spec = conversionPatternSpec(GpuDialect.ShflSyncOp.operation_name), .rewrite = rewriteShflSync },
    .{ .spec = conversionPatternSpec(GpuDialect.WarpReduceOp.operation_name), .rewrite = rewriteWarpReduce },
    .{ .spec = conversionPatternSpec(GpuDialect.WarpScanOp.operation_name), .rewrite = rewriteWarpScan },
    .{ .spec = conversionPatternSpec(GpuDialect.MmaSyncOp.operation_name), .rewrite = rewriteMmaSync },
    .{ .spec = conversionPatternSpec(GpuDialect.FenceOp.operation_name), .rewrite = rewriteFence },
    .{ .spec = conversionPatternSpec(GpuDialect.CpAsyncSharedOp.operation_name), .rewrite = rewriteCpAsyncShared },
    .{ .spec = conversionPatternSpec(GpuDialect.CpAsyncCommitOp.operation_name), .rewrite = rewriteCpAsyncCommit },
    .{ .spec = conversionPatternSpec(GpuDialect.CpAsyncWaitOp.operation_name), .rewrite = rewriteCpAsyncWait },
    .{ .spec = conversionPatternSpec(MemrefDialect.LoadOp.operation_name), .rewrite = rewriteMemrefLoad },
    .{ .spec = conversionPatternSpec(MemrefDialect.StoreOp.operation_name), .rewrite = rewriteMemrefStore },
    .{ .spec = conversionPatternSpec(MemrefDialect.AtomicRmwOp.operation_name), .rewrite = rewriteMemrefAtomicRmw },
    .{ .spec = conversionPatternSpec(MemrefDialect.AtomicCasOp.operation_name), .rewrite = rewriteMemrefAtomicCas },
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
    .name = "nvptx",
    .description = gpu_to_nvptx_pass_description,
    .target_dialect_name = NvptxDialect.name,
    .legality = .{
        .legal_dialects = legal_dialects[0..],
        .illegal_ops = illegal_ops[0..],
    },
    .conversion_patterns = conversion_patterns[0..],
    .pass_name = gpu_to_nvptx_pass_name,
    .pass_description = gpu_to_nvptx_pass_description,
};

pub fn createGpuToNvptxPass() Pass {
    return .{
        .name = gpu_to_nvptx_pass_name,
        .description = gpu_to_nvptx_pass_description,
        .run_fn = runGpuToNvptx,
        .mutation_scope = .isolated,
        .dependent_dialects = passes.dialectDependencies(&.{"nvptx"}),
    };
}

pub const pass_registration = passes.PassRegistration{
    .name = gpu_to_nvptx_pass_name,
    .description = gpu_to_nvptx_pass_description,
    .pass = createGpuToNvptxPass(),
};

fn runGpuToNvptx(ctx: *PassContext) PassResult {
    ir.dialects.loadDialectSpec(ctx.ir_ctx, NvptxDialect.spec) catch return .failure;

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

fn setDialectAttr(rewriter: *PatternRewriter, op: *ir.Operation, name: []const u8, dialect: []const u8, payload: []const u8) !void {
    const attr = try rewriter.ir_ctx.getDialectAttr(dialect, payload);
    try rewriter.setAttr(op, name, attr);
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
    return rewriteGpuIndex(op, rewriter, NvptxDialect.ThreadIdxOp.operation_name);
}

fn rewriteBlockIdx(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteGpuIndex(op, rewriter, NvptxDialect.BlockIdxOp.operation_name);
}

fn rewriteBlockDim(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteGpuIndex(op, rewriter, NvptxDialect.BlockDimOp.operation_name);
}

fn rewriteGridDim(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteGpuIndex(op, rewriter, NvptxDialect.GridDimOp.operation_name);
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
    const dim_attr = rewriter.ir_ctx.getDialectAttr("nvptx.dim", dim.toString()) catch return .failure;
    state.addAttributes(&.{.{ .name = "dim", .value = dim_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteGlobalIdx(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const dim = getDimensionAttr(op) orelse return .failure;
    const result = op.getResult(0) orelse return .failure;

    var cta_state = ir.Operation.State.init(NvptxDialect.BlockIdxOp.operation_name, op.location);
    cta_state.addTypes(&.{result.type});
    const cta = rewriter.create(cta_state) catch return .failure;
    setDialectAttr(rewriter, cta, "dim", "nvptx.dim", dim.toString()) catch return .failure;

    var ntid_state = ir.Operation.State.init(NvptxDialect.BlockDimOp.operation_name, op.location);
    ntid_state.addTypes(&.{result.type});
    const ntid = rewriter.create(ntid_state) catch return .failure;
    setDialectAttr(rewriter, ntid, "dim", "nvptx.dim", dim.toString()) catch return .failure;

    var tid_state = ir.Operation.State.init(NvptxDialect.ThreadIdxOp.operation_name, op.location);
    tid_state.addTypes(&.{result.type});
    const tid = rewriter.create(tid_state) catch return .failure;
    setDialectAttr(rewriter, tid, "dim", "nvptx.dim", dim.toString()) catch return .failure;

    var mul_state = ir.Operation.State.init(ArithDialect.MulOp.operation_name, op.location);
    mul_state.addOperands(&.{ cta.getResult(0).?, ntid.getResult(0).? });
    mul_state.addTypes(&.{result.type});
    const mul_op = rewriter.create(mul_state) catch return .failure;

    var add_state = ir.Operation.State.init(ArithDialect.AddOp.operation_name, op.location);
    add_state.addOperands(&.{ mul_op.getResult(0).?, tid.getResult(0).? });
    add_state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, add_state) catch return .failure;
    return .success;
}

fn rewriteLaneId(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteGpuRegister(op, rewriter, NvptxDialect.LaneIdOp.operation_name);
}

fn rewriteWarpId(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    return rewriteGpuRegister(op, rewriter, NvptxDialect.WarpIdOp.operation_name);
}

fn rewriteGpuRegister(
    op: *ir.Operation,
    rewriter: *PatternRewriter,
    target_name: []const u8,
) rewrite.PatternResult {
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(target_name, op.location);
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteBarrier(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const scope = getScopeAttr(op) orelse return .failure;
    const target_name = switch (scope) {
        .thread => {
            rewriter.eraseOp(op) catch return .failure;
            return .success;
        },
        .warp => NvptxDialect.WarpBarrierAllOp.operation_name,
        .block => NvptxDialect.Barrier0Op.operation_name,
        .cluster, .device, .system => return .failure,
    };
    const state = ir.Operation.State.init(target_name, op.location);
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteSyncWarp(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const sync = GpuDialect.SyncWarpOp{ .op = op };
    var state = ir.Operation.State.init(NvptxDialect.SyncWarpOp.operation_name, op.location);
    state.addOperands(&.{sync.getMask()});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteActiveMask(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(NvptxDialect.ActiveMaskOp.operation_name, op.location);
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteAllSync(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const all = GpuDialect.AllSyncOp{ .op = op };
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(NvptxDialect.AllSyncOp.operation_name, op.location);
    state.addOperands(&.{ all.getMask(), all.getPredicate() });
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteAnySync(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const any = GpuDialect.AnySyncOp{ .op = op };
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(NvptxDialect.AnySyncOp.operation_name, op.location);
    state.addOperands(&.{ any.getMask(), any.getPredicate() });
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteBallotSync(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const ballot = GpuDialect.BallotSyncOp{ .op = op };
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(NvptxDialect.BallotSyncOp.operation_name, op.location);
    state.addOperands(&.{ ballot.getMask(), ballot.getPredicate() });
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteShflSync(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const shfl = GpuDialect.ShflSyncOp{ .op = op };
    const mode = shfl.getMode() orelse return .failure;
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(NvptxDialect.ShflSyncOp.operation_name, op.location);
    state.addOperands(&.{ shfl.getMask(), shfl.getSrc(), shfl.getLaneOrDelta() });
    state.addTypes(&.{result.type});
    const mode_attr = rewriter.ir_ctx.getDialectAttr("nvptx.shuffle_mode", mode.toString()) catch return .failure;
    state.addAttributes(&.{.{ .name = "mode", .value = mode_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteWarpReduce(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const reduce = GpuDialect.WarpReduceOp{ .op = op };
    const kind = reduce.getOpKind() orelse return .failure;
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(NvptxDialect.WarpReduceOp.operation_name, op.location);
    state.addOperands(&.{ reduce.getMask(), reduce.getValue() });
    state.addTypes(&.{result.type});
    const op_attr = rewriter.ir_ctx.getDialectAttr("nvptx.warp_op", kind.toString()) catch return .failure;
    state.addAttributes(&.{.{ .name = "op", .value = op_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteWarpScan(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const scan = GpuDialect.WarpScanOp{ .op = op };
    const kind = scan.getOpKind() orelse return .failure;
    const inclusive = scan.isInclusive();
    const result = op.getResult(0) orelse return .failure;
    var state = ir.Operation.State.init(NvptxDialect.WarpScanOp.operation_name, op.location);
    state.addOperands(&.{ scan.getMask(), scan.getValue() });
    state.addTypes(&.{result.type});
    const op_attr = rewriter.ir_ctx.getDialectAttr("nvptx.warp_op", kind.toString()) catch return .failure;
    const inclusive_attr = rewriter.ir_ctx.getBoolAttr(inclusive) catch return .failure;
    state.addAttributes(&.{
        .{ .name = "op", .value = op_attr },
        .{ .name = "inclusive", .value = inclusive_attr },
    });
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteMmaSync(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const mma = GpuDialect.MmaSyncOp{ .op = op };
    const shape = mma.getShape() orelse return .failure;
    if (op.operands.items.len != 10 or op.getNumResults() != 4) return .failure;
    var state = ir.Operation.State.init(NvptxDialect.MmaSyncOp.operation_name, op.location);
    state.addOperands(&.{
        mma.getA(0), mma.getA(1), mma.getA(2), mma.getA(3),
        mma.getB(0), mma.getB(1), mma.getC(0), mma.getC(1),
        mma.getC(2), mma.getC(3),
    });
    state.addTypes(&.{
        op.getResult(0).?.type,
        op.getResult(1).?.type,
        op.getResult(2).?.type,
        op.getResult(3).?.type,
    });
    var shape_buf: [32]u8 = undefined;
    const shape_str = shape.toString(shape_buf[0..]) catch return .failure;
    const shape_attr = rewriter.ir_ctx.getDialectAttr("nvptx.mma_shape", shape_str) catch return .failure;
    state.addAttributes(&.{.{ .name = "shape", .value = shape_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteFence(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const state = ir.Operation.State.init(NvptxDialect.FenceDeviceOp.operation_name, op.location);
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteCpAsyncShared(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const copy = GpuDialect.CpAsyncSharedOp{ .op = op };
    const bytes = copy.getBytes() orelse return .failure;
    var state = ir.Operation.State.init(NvptxDialect.CpAsyncSharedOp.operation_name, op.location);
    state.addOperands(&.{ copy.getDst(), copy.getDstIndex(), copy.getSrc(), copy.getSrcIndex() });
    const bytes_attr = rewriter.ir_ctx.getI64Attr(@intCast(bytes)) catch return .failure;
    state.addAttributes(&.{.{ .name = "bytes", .value = bytes_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteCpAsyncCommit(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const state = ir.Operation.State.init(NvptxDialect.CpAsyncCommitOp.operation_name, op.location);
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteCpAsyncWait(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const wait = GpuDialect.CpAsyncWaitOp{ .op = op };
    const groups = wait.getGroups() orelse return .failure;
    var state = ir.Operation.State.init(NvptxDialect.CpAsyncWaitOp.operation_name, op.location);
    const groups_attr = rewriter.ir_ctx.getI64Attr(@intCast(groups)) catch return .failure;
    state.addAttributes(&.{.{ .name = "groups", .value = groups_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteMemrefLoad(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const load = MemrefDialect.LoadOp{ .op = op };
    const result = op.getResult(0) orelse return .failure;
    const memref = load.getMemref();
    const addr_space = memrefAddressSpace(memref.type) orelse return .failure;
    const op_name = switch (addr_space) {
        .local => NvptxDialect.LoadLocalOp.operation_name,
        .shared => NvptxDialect.LoadSharedOp.operation_name,
        else => NvptxDialect.LoadGlobalOp.operation_name,
    };

    var state = ir.Operation.State.init(op_name, op.location);
    state.addOperands(&.{ memref, load.getIndex() });
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteMemrefStore(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const store = MemrefDialect.StoreOp{ .op = op };
    const memref = store.getMemref();
    const addr_space = memrefAddressSpace(memref.type) orelse return .failure;
    const op_name = switch (addr_space) {
        .local => NvptxDialect.StoreLocalOp.operation_name,
        .shared => NvptxDialect.StoreSharedOp.operation_name,
        else => NvptxDialect.StoreGlobalOp.operation_name,
    };

    var state = ir.Operation.State.init(op_name, op.location);
    state.addOperands(&.{ store.getValue(), memref, store.getIndex() });
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteMemrefAtomicRmw(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const atomic = MemrefDialect.AtomicRmwOp{ .op = op };
    const result = op.getResult(0) orelse return .failure;
    const kind = atomic.getKind() orelse return .failure;
    const memref = atomic.getMemref();
    const addr_space = memrefAddressSpace(memref.type) orelse return .failure;
    const op_name = switch (addr_space) {
        .shared => NvptxDialect.AtomicSharedOp.operation_name,
        .local => return .failure,
        else => NvptxDialect.AtomicGlobalOp.operation_name,
    };

    var state = ir.Operation.State.init(op_name, op.location);
    state.addOperands(&.{ atomic.getValue(), memref, atomic.getIndex() });
    state.addTypes(&.{result.type});
    const kind_attr = rewriter.ir_ctx.getDialectAttr("nvptx.atomic_kind", kind.toString()) catch return .failure;
    state.addAttributes(&.{.{ .name = "kind", .value = kind_attr }});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn rewriteMemrefAtomicCas(op: *ir.Operation, rewriter: *PatternRewriter) rewrite.PatternResult {
    const atomic = MemrefDialect.AtomicCasOp{ .op = op };
    const result = op.getResult(0) orelse return .failure;
    const memref = atomic.getMemref();
    const addr_space = memrefAddressSpace(memref.type) orelse return .failure;
    const op_name = switch (addr_space) {
        .shared => NvptxDialect.AtomicCasSharedOp.operation_name,
        .local => return .failure,
        else => NvptxDialect.AtomicCasGlobalOp.operation_name,
    };

    var state = ir.Operation.State.init(op_name, op.location);
    state.addOperands(&.{ atomic.getExpected(), atomic.getDesired(), memref, atomic.getIndex() });
    state.addTypes(&.{result.type});
    _ = rewriter.replaceOpWithNewOp(op, state) catch return .failure;
    return .success;
}

fn memrefAddressSpace(typ: ir.Type) ?MemrefAddressSpace {
    const name = typ.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, name, MemrefDialect.name)) return null;
    const param_key = typ.getDialectParamKey() orelse return null;
    const params = MemrefDialect.parseMemrefParams(param_key) orelse return null;
    return params.addr_space;
}

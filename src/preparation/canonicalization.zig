const std = @import("std");
const alloc_fixed = @import("alloc_fixed");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const dialect_mod = accy_choir.dialect;

const ir = choir.ir;
const rewrite = ir.rewrite;
const passes = choir.passes;
const work = passes.pass.work;
const AccyDialect = dialect_mod.AccyDialect;

pub const canonicalization_pass_name = "accy-choir-canonicalize";
pub const canonicalization_pass_description =
    "Canonicalize identity Accy Choir tensor operations";
const RewriteFn = *const fn (*ir.Operation, *rewrite.PatternRewriter) rewrite.PatternResult;

pub const CanonicalizationPatternEntry = struct {
    spec: rewrite.RewritePatternSpec,
    rewrite: RewriteFn,
};

pub const canonicalization_pattern_entries = [_]CanonicalizationPatternEntry{
    .{ .spec = .{ .name = "accy-reshape-identity", .root_op_name = AccyDialect.ReshapeOp.operation_name, .products = .none }, .rewrite = rewriteReshape },
    .{ .spec = .{ .name = "accy-transpose-identity", .root_op_name = AccyDialect.TransposeOp.operation_name, .products = .none }, .rewrite = rewriteTranspose },
    .{ .spec = .{ .name = "accy-broadcast-identity", .root_op_name = AccyDialect.BroadcastOp.operation_name, .products = .none }, .rewrite = rewriteBroadcast },
    .{ .spec = .{ .name = "accy-broadcast-in-dim-identity", .root_op_name = AccyDialect.BroadcastInDimOp.operation_name, .products = .none }, .rewrite = rewriteBroadcastInDim },
    .{ .spec = .{ .name = "accy-slice-identity", .root_op_name = AccyDialect.SliceOp.operation_name, .products = .none }, .rewrite = rewriteSlice },
    .{ .spec = .{ .name = "accy-concatenate-single-input", .root_op_name = AccyDialect.ConcatenateOp.operation_name, .products = .none }, .rewrite = rewriteConcatenate },
    .{ .spec = .{ .name = "accy-dot-flatten-shared-rhs", .root_op_name = AccyDialect.DotGeneralOp.operation_name, .products = .none }, .rewrite = rewriteDotGeneral },
    .{ .spec = .{ .name = "accy-cumsum-attach-scratch", .root_op_name = AccyDialect.CumsumOp.operation_name, .products = .none }, .rewrite = rewriteCumsum },
};

pub const cumsum_block_tile = 8192;

const greedy_config: passes.GreedyRewriteConfig = .{};

const AccyCanonicalizationPass = passes.CanonicalizationPass(.{
    .name = canonicalization_pass_name,
    .description = canonicalization_pass_description,
    .populate_patterns = populateCanonicalizationPatterns,
    .greedy_config = greedy_config,
});

pub fn canonicalizationPass() passes.Pass {
    var result = AccyCanonicalizationPass.init();
    result.work_contract = .{
        .identity = .{ .name = canonicalization_pass_name, .version = 1 },
        .estimate = canonicalizationWork,
    };
    return result;
}

const CanonicalizationWorkFacts = struct {
    type_key_bytes: u64 = 0,
    list_bytes: u64 = 0,
    broadcasts: u64 = 0,
    dots: u64 = 0,
    scans: u64 = 0,

    fn visit(self: *CanonicalizationWorkFacts, op: *ir.Operation) !ir.WalkResult {
        const namespace = op.name.getDialectNamespace();
        if (!std.mem.eql(u8, namespace, "accy") and !std.mem.eql(u8, namespace, "func") and
            !std.mem.eql(u8, namespace, "builtin")) return error.UnsupportedDialect;
        if (op.hasInterface(ir.interfaces.FoldOpInterface)) return error.MissingWorkContract;
        const name = op.name.name;
        if (std.mem.eql(u8, name, AccyDialect.BroadcastOp.operation_name) or
            std.mem.eql(u8, name, AccyDialect.BroadcastInDimOp.operation_name))
        {
            self.broadcasts = try work.add(self.broadcasts, 1);
        }
        if (std.mem.eql(u8, name, AccyDialect.DotGeneralOp.operation_name)) {
            self.dots = try work.add(self.dots, 1);
        }
        if (std.mem.eql(u8, name, AccyDialect.CumsumOp.operation_name)) {
            self.scans = try work.add(self.scans, 1);
        }
        for (op.results.items) |*value| self.typeKey(value.type);
        for (op.getOperandValues()) |value| self.typeKey(value.type);
        var attributes = op.getAttrs();
        while (attributes.next()) |entry| {
            if (entry.value.cast(ir.Attribute.DialectAttr)) |attr| {
                self.list_bytes = @max(self.list_bytes, attr.payload.len);
            }
        }
        return .advance;
    }

    fn typeKey(self: *CanonicalizationWorkFacts, typ: ir.Type) void {
        if (typ.getDialectParamKey()) |key| self.type_key_bytes = @max(self.type_key_bytes, key.len);
    }
};

/// The compile chain calls this before the pass runs, to charge the costs a pass declares before it
/// runs against the caller's limits as the work bound, so compilation can refuse the pass on them.
/// The rules this pass admits remove operations that change nothing (reshape, transpose, broadcast,
/// `broadcast_in_dim`, slice, and a concatenate with one input), rewrite a plain broadcast as one
/// `broadcast_in_dim`, merge a chain of `broadcast_in_dim` into one, split one batched dot into a
/// reshape, a dot and a reshape, and attach one scratch value to a cumulative sum. No rule makes a
/// chain longer, so the operations the pass can create are bounded by counts taken from the input:
/// at most three per dot, two per cumulative sum, and a quadratic term in the number of broadcasts.
/// The bound multiplies those counts by the rewriter's iteration limit.
fn canonicalizationWork(input: work.Input) !work.Bounds {
    const counts = try work.Census.inspect(input.operation);
    var facts: CanonicalizationWorkFacts = .{};
    _ = try input.operation.walk(.{ .order = .pre_order }, &facts, CanonicalizationWorkFacts.visit);
    const patterns = try canonicalizationPatternStorage(input.operation.context);
    const broadcasts = try work.multiply(facts.broadcasts, try work.add(facts.broadcasts, 1));
    const dot_and_scan = try work.add(try work.multiply(3, facts.dots), try work.multiply(2, facts.scans));
    const generated = try work.add(broadcasts, dot_and_scan);
    const traversed = try work.add(counts.operations, try work.multiply(2, generated));
    const attempts = try work.multiply(greedy_config.max_iterations, traversed);
    const dimensions = try work.multiply(try work.add(facts.type_key_bytes, 128), @sizeOf(i64));
    const scratch = try work.multiply(12, try work.add(
        try work.add(dimensions, facts.list_bytes),
        @alignOf(i64),
    ));
    const queues = try work.multiply(2, try work.arrayListGrowth(*ir.Operation, traversed));
    const iterations = try work.multiply(greedy_config.max_iterations, queues);
    const workspace = try work.add(patterns.bytes, try work.add(
        iterations,
        try work.multiply(attempts, scratch),
    ));
    const units = try work.add(try work.add(counts.atoms, counts.input_bytes), generated);
    const scans = try work.multiply(try work.add(patterns.patterns, 64), try work.multiply(attempts, try work.add(units, 1)));
    return .{
        .work = .{
            .input_bytes = try work.add(counts.input_bytes, patterns.name_bytes),
            .output_bytes = input.operation.context.capacity.storage_bytes,
            .structural_visits = try work.add(scans, patterns.visits),
            .rewrite_attempts = try work.multiply(attempts, canonicalization_pattern_entries.len),
            .allocation_capacity = workspace,
        },
        .workspace = workspace,
    };
}

fn canonicalizationPatternStorage(
    context: *ir.Context,
) !passes.canonicalization.PatternPopulationBounds {
    const Interface = rewrite.DialectCanonicalizationInterface;
    const known = choir.dialects.arith.canonicalization_patterns[0..];
    var interfaces = context.dialect_registry.interfaces.iterator();
    while (interfaces.next()) |entry| {
        for (entry.value_ptr.items) |interface| {
            if (interface.id != Interface.id) continue;
            const patterns = Interface.fromOpaque(interface.vtable).patterns;
            if (patterns.len != 0 and (patterns.len != known.len or patterns.ptr != known.ptr)) {
                return error.MissingWorkContract;
            }
        }
    }
    const extra = comptime blk: {
        var specs: [canonicalization_pattern_entries.len]rewrite.RewritePatternSpec = undefined;
        for (canonicalization_pattern_entries, 0..) |entry, index| specs[index] = entry.spec;
        break :blk specs;
    };
    return passes.canonicalization.patternPopulationBounds(context, &extra);
}

pub fn canonicalizeModule(
    allocator: std.mem.Allocator,
    choir_module: *ir.Operation,
    ctx: *ir.Context,
) !usize {
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    pm.enableVerifier();
    try pm.addPass(canonicalizationPass());
    if (pm.run(choir_module, ctx) == .failure) return error.CanonicalizationFailed;
    return pm.stats.passes_modified;
}

pub fn populateCanonicalizationPatterns(patterns: *rewrite.RewritePatternSet) !void {
    for (canonicalization_pattern_entries) |entry| {
        try patterns.add(rewrite.RewritePattern.init(entry.spec, entry.rewrite));
    }
}

fn rewriteResult(result: anyerror!bool) rewrite.PatternResult {
    return if (result catch return .failure) .success else .failure;
}

fn rewriteReshape(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    return rewriteResult(canonicalizeReshape(rewriter.allocator, op, rewriter));
}

fn rewriteTranspose(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    return rewriteResult(canonicalizeTranspose(rewriter.allocator, op, rewriter));
}

fn rewriteBroadcast(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    return rewriteResult(canonicalizeBroadcast(rewriter.allocator, op, rewriter));
}

fn rewriteBroadcastInDim(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    return rewriteResult(canonicalizeBroadcastInDim(rewriter.allocator, op, rewriter));
}

fn rewriteSlice(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    return rewriteResult(canonicalizeSlice(rewriter.allocator, op, rewriter));
}

fn rewriteConcatenate(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    return rewriteResult(canonicalizeConcatenate(rewriter.allocator, op, rewriter));
}

fn broadcastBatchedSource(rhs: *ir.Value) ?*ir.Value {
    const def_any = rhs.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!std.mem.eql(u8, def_op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) return null;
    if (def_op.getNumOperands() != 1) return null;
    var dims_buffer: [8]i64 = undefined;
    const attr = def_op.getAttrAs(ir.Attribute.DialectAttr, "broadcast_dims") orelse return null;
    if (attr.payload.len != 2 * @sizeOf(i64)) return null;
    @memcpy(std.mem.sliceAsBytes(dims_buffer[0..2]), attr.payload[0 .. 2 * @sizeOf(i64)]);
    if (dims_buffer[0] != 1 or dims_buffer[1] != 2) return null;
    return def_op.getOperand(0);
}

fn rewriteDotGeneral(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    return rewriteResult(canonicalizeDotGeneral(rewriter.allocator, op, rewriter));
}

fn rewriteCumsum(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) rewrite.PatternResult {
    return rewriteResult(canonicalizeCumsum(rewriter.allocator, op, rewriter));
}

fn canonicalizeCumsum(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    if (op.getNumOperands() != 1 or op.getNumResults() != 1) return false;
    const input = op.getOperand(0) orelse return false;
    const result = op.getResult(0) orelse return false;

    const shape = try tensorShapeAlloc(allocator, input.type) orelse return false;
    defer allocator.free(shape);
    if (shape.len != 1) return false;
    const total = shape[0];
    if (total <= cumsum_block_tile) return false;

    const blocks = @divTrunc(total + cumsum_block_tile - 1, cumsum_block_tile);
    const words = 1 + 3 * blocks;

    const ctx = rewriter.ir_ctx;
    const scratch_type = try dialect_mod.accyTensorType(ctx, .u32, &.{words});
    const scratch = try AccyDialect.ScratchOp.create(ctx, op.location, scratch_type, words);
    _ = try rewriter.insert(scratch.op);

    const axis_attr = op.getAttrAs(ir.Attribute.IntegerAttr, "axis") orelse return false;
    const replacement = try AccyDialect.CumsumOp.createWithScratch(ctx, op.location, input, scratch.getResult(), result.type, axis_attr.getValue());
    _ = try rewriter.insert(replacement.op);
    try rewriter.replaceOpWithOperation(op, replacement.op);
    return true;
}

fn canonicalizeDotGeneral(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    if (op.getNumOperands() != 2 or op.getNumResults() != 1) return false;
    const lhs = op.getOperand(0) orelse return false;
    var rhs = op.getOperand(1) orelse return false;
    const result = op.getResult(0) orelse return false;

    const lhs_shape = try tensorShapeAlloc(allocator, lhs.type) orelse return false;
    defer allocator.free(lhs_shape);
    const result_shape = try tensorShapeAlloc(allocator, result.type) orelse return false;
    defer allocator.free(result_shape);
    if (lhs_shape.len != 3 or result_shape.len != 3) return false;

    const lhs_contract = try readI64ListAttrAlloc(allocator, op, "lhs_contract", dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("lhs_contract")) orelse return false;
    defer allocator.free(lhs_contract);
    const rhs_contract = try readI64ListAttrAlloc(allocator, op, "rhs_contract", dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("rhs_contract")) orelse return false;
    defer allocator.free(rhs_contract);
    const lhs_batch = try readI64ListAttrAlloc(allocator, op, "lhs_batch", dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("lhs_batch")) orelse return false;
    defer allocator.free(lhs_batch);
    const rhs_batch = try readI64ListAttrAlloc(allocator, op, "rhs_batch", dialect_mod.AccyDialect.DotGeneralOp.dialectAttrName("rhs_batch")) orelse return false;
    defer allocator.free(rhs_batch);

    if (lhs_contract.len != 1 or rhs_contract.len != 1) return false;
    if (lhs_contract[0] != 2) return false;

    if (rhs_batch.len == 0) {
        if (rhs_contract[0] != 0) return false;
        if (lhs_batch.len > 1) return false;
        if (lhs_batch.len == 1 and lhs_batch[0] != 0) return false;
    } else {
        if (lhs_batch.len != 1 or rhs_batch.len != 1) return false;
        if (lhs_batch[0] != 0 or rhs_batch[0] != 0) return false;
        if (rhs_contract[0] != 1) return false;
        rhs = broadcastBatchedSource(rhs) orelse return false;
    }

    const rhs_shape = try tensorShapeAlloc(allocator, rhs.type) orelse return false;
    defer allocator.free(rhs_shape);
    if (rhs_shape.len != 2) return false;

    const batch = lhs_shape[0];
    const m = lhs_shape[1];
    const k = lhs_shape[2];
    const n = rhs_shape[1];
    if (rhs_shape[0] != k) return false;
    if (result_shape[0] != batch or result_shape[1] != m or result_shape[2] != n) return false;
    const flat_m = std.math.mul(i64, batch, m) catch return false;

    var dtype_arena_buffer: [256]u8 = undefined;
    var dtype_arena = alloc_fixed.FixedBuffer.init(dtype_arena_buffer[0..]);
    const lhs_decoded = dialect_mod.decodeTensorType(dtype_arena.allocator(), lhs.type) catch return false;

    const ctx = rewriter.ir_ctx;
    const flat_lhs_type = try dialect_mod.accyTensorType(ctx, lhs_decoded.dtype, &.{ flat_m, k });
    const flat_out_type = try dialect_mod.accyTensorType(ctx, lhs_decoded.dtype, &.{ flat_m, n });

    const flat_lhs = try dialect_mod.AccyDialect.ReshapeOp.create(ctx, op.location, lhs, flat_lhs_type, &.{ flat_m, k });
    _ = try rewriter.insert(flat_lhs.op);
    const flat_dot = try dialect_mod.AccyDialect.DotGeneralOp.create(ctx, op.location, flat_lhs.getResult(), rhs, flat_out_type, &.{}, &.{}, &.{1}, &.{0});
    _ = try rewriter.insert(flat_dot.op);
    const restored = try dialect_mod.AccyDialect.ReshapeOp.create(ctx, op.location, flat_dot.getResult(), result.type, result_shape);
    _ = try rewriter.insert(restored.op);
    try rewriter.replaceOpWithOperation(op, restored.op);
    return true;
}

fn canonicalizeReshape(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    const input = identityUnaryInput(op) orelse return false;
    const input_shape = try tensorShapeAlloc(allocator, input.type) orelse return false;
    defer allocator.free(input_shape);
    const new_shape = try readI64ListAttrAlloc(allocator, op, "new_shape", dialect_mod.AccyDialect.ReshapeOp.dialectAttrName("new_shape")) orelse return false;
    defer allocator.free(new_shape);
    if (!std.mem.eql(i64, input_shape, new_shape)) return false;
    return replaceWithInput(op, input, rewriter);
}

fn canonicalizeTranspose(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    const input = identityUnaryInput(op) orelse return false;
    const input_shape = try tensorShapeAlloc(allocator, input.type) orelse return false;
    defer allocator.free(input_shape);
    const permutation = try readI64ListAttrAlloc(allocator, op, "permutation", dialect_mod.AccyDialect.TransposeOp.dialectAttrName("permutation")) orelse return false;
    defer allocator.free(permutation);
    if (permutation.len != input_shape.len) return false;
    if (!isIdentityPermutation(permutation)) return false;
    return replaceWithInput(op, input, rewriter);
}

fn canonicalizeBroadcast(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    if (op.getNumOperands() != 1 or op.getNumResults() != 1) return false;
    const input = op.getOperand(0) orelse return false;
    const result = op.getResult(0) orelse return false;
    const sizes = try readI64ListAttrAlloc(allocator, op, "sizes", dialect_mod.AccyDialect.BroadcastOp.dialectAttrName("sizes")) orelse return false;
    defer allocator.free(sizes);
    if (sizes.len == 0) {
        if (!result.type.eql(input.type)) return false;
        return replaceWithInput(op, input, rewriter);
    }

    const input_shape = try tensorShapeAlloc(allocator, input.type) orelse return false;
    defer allocator.free(input_shape);

    const result_shape = try allocator.alloc(i64, sizes.len + input_shape.len);
    defer allocator.free(result_shape);
    @memcpy(result_shape[0..sizes.len], sizes);
    @memcpy(result_shape[sizes.len..], input_shape);

    const broadcast_dims = try allocator.alloc(i64, input_shape.len);
    defer allocator.free(broadcast_dims);
    for (broadcast_dims, 0..) |*dim, index| dim.* = @intCast(sizes.len + index);

    const replacement = try dialect_mod.AccyDialect.BroadcastInDimOp.create(
        rewriter.ir_ctx,
        op.location,
        input,
        result.type,
        broadcast_dims,
        result_shape,
    );
    _ = try rewriter.insert(replacement.op);
    try rewriter.replaceOpWithOperation(op, replacement.op);
    return true;
}

fn canonicalizeBroadcastInDim(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    if (try collapseChainedBroadcastInDim(allocator, op, rewriter)) return true;
    const input = identityUnaryInput(op) orelse return false;
    const input_shape = try tensorShapeAlloc(allocator, input.type) orelse return false;
    defer allocator.free(input_shape);
    const broadcast_dims = try readI64ListAttrAlloc(allocator, op, "broadcast_dims", dialect_mod.AccyDialect.BroadcastInDimOp.dialectAttrName("broadcast_dims")) orelse return false;
    defer allocator.free(broadcast_dims);
    const result_shape = try readI64ListAttrAlloc(allocator, op, "result_shape", dialect_mod.AccyDialect.BroadcastInDimOp.dialectAttrName("result_shape")) orelse return false;
    defer allocator.free(result_shape);
    if (broadcast_dims.len != input_shape.len) return false;
    if (!isIdentityPermutation(broadcast_dims)) return false;
    if (!std.mem.eql(i64, input_shape, result_shape)) return false;
    return replaceWithInput(op, input, rewriter);
}

fn collapseChainedBroadcastInDim(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    if (op.getNumOperands() != 1 or op.getNumResults() != 1) return false;
    const mid = op.getOperand(0) orelse return false;
    const result = op.getResult(0) orelse return false;
    const inner_any = mid.getDefiningOp() orelse return false;
    const inner: *ir.Operation = @ptrCast(@alignCast(inner_any));
    if (!std.mem.eql(u8, inner.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) return false;
    if (inner.getNumOperands() != 1) return false;
    const source = inner.getOperand(0) orelse return false;

    const outer_dims = try readI64ListAttrAlloc(allocator, op, "broadcast_dims", dialect_mod.AccyDialect.BroadcastInDimOp.dialectAttrName("broadcast_dims")) orelse return false;
    defer allocator.free(outer_dims);
    const outer_shape = try readI64ListAttrAlloc(allocator, op, "result_shape", dialect_mod.AccyDialect.BroadcastInDimOp.dialectAttrName("result_shape")) orelse return false;
    defer allocator.free(outer_shape);
    const inner_dims = try readI64ListAttrAlloc(allocator, inner, "broadcast_dims", dialect_mod.AccyDialect.BroadcastInDimOp.dialectAttrName("broadcast_dims")) orelse return false;
    defer allocator.free(inner_dims);

    const composed = try allocator.alloc(i64, inner_dims.len);
    defer allocator.free(composed);
    for (inner_dims, 0..) |mid_dim, index| {
        if (mid_dim < 0 or mid_dim >= outer_dims.len) return false;
        composed[index] = outer_dims[@intCast(mid_dim)];
    }

    const replacement = try dialect_mod.AccyDialect.BroadcastInDimOp.create(
        rewriter.ir_ctx,
        op.location,
        source,
        result.type,
        composed,
        outer_shape,
    );
    _ = try rewriter.insert(replacement.op);
    try rewriter.replaceOpWithOperation(op, replacement.op);
    return true;
}

fn canonicalizeSlice(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    const input = identityUnaryInput(op) orelse return false;
    const input_shape = try tensorShapeAlloc(allocator, input.type) orelse return false;
    defer allocator.free(input_shape);
    const starts = try readI64ListAttrAlloc(allocator, op, "starts", dialect_mod.AccyDialect.SliceOp.dialectAttrName("starts")) orelse return false;
    defer allocator.free(starts);
    const limits = try readI64ListAttrAlloc(allocator, op, "limits", dialect_mod.AccyDialect.SliceOp.dialectAttrName("limits")) orelse return false;
    defer allocator.free(limits);
    const strides = try readI64ListAttrAlloc(allocator, op, "strides", dialect_mod.AccyDialect.SliceOp.dialectAttrName("strides")) orelse return false;
    defer allocator.free(strides);

    if (starts.len != input_shape.len or
        limits.len != input_shape.len or
        strides.len != input_shape.len)
    {
        return false;
    }
    for (starts, limits, strides, input_shape) |start, limit, stride, dim| {
        if (start != 0 or limit != dim or stride != 1) return false;
    }
    return replaceWithInput(op, input, rewriter);
}

fn canonicalizeConcatenate(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    if (op.getNumOperands() != 1 or op.getNumResults() != 1) return false;
    const input = op.getOperand(0) orelse return false;
    const result = op.getResult(0) orelse return false;
    if (!result.type.eql(input.type)) return false;
    const input_shape = try tensorShapeAlloc(allocator, input.type) orelse return false;
    defer allocator.free(input_shape);
    const dimension = readIntegerAttr(op, "dimension") orelse return false;
    if (dimension < 0 or dimension >= @as(i64, @intCast(input_shape.len))) return false;
    try rewriter.replaceOpWithValue(op, input);
    return true;
}

fn identityUnaryInput(op: *ir.Operation) ?*ir.Value {
    if (op.getNumOperands() != 1 or op.getNumResults() != 1) return null;
    const input = op.getOperand(0) orelse return null;
    const result = op.getResult(0) orelse return null;
    if (!result.type.eql(input.type)) return null;
    return input;
}

fn replaceWithInput(
    op: *ir.Operation,
    input: *ir.Value,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    try rewriter.replaceOpWithValue(op, input);
    return true;
}

pub fn readDialectPayload(op: *const ir.Operation, attr_name: []const u8, dialect_attr_name: []const u8) ?[]const u8 {
    const attr = op.getAttr(attr_name) orelse return null;
    if (!std.mem.eql(u8, attr.abstract.name, dialect_attr_name)) return null;
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
    return dialect_attr.payload;
}

pub fn readI64ListAttrAlloc(
    allocator: std.mem.Allocator,
    op: *const ir.Operation,
    attr_name: []const u8,
    dialect_attr_name: []const u8,
) !?[]i64 {
    const payload = readDialectPayload(op, attr_name, dialect_attr_name) orelse return null;
    if (payload.len % @sizeOf(i64) != 0) return null;
    const values = try allocator.alloc(i64, payload.len / @sizeOf(i64));
    for (values, 0..) |*value, i| {
        const start = i * @sizeOf(i64);
        @memcpy(std.mem.asBytes(value), payload[start..][0..@sizeOf(i64)]);
    }
    return values;
}

fn readIntegerAttr(op: *const ir.Operation, attr_name: []const u8) ?i64 {
    const attr = op.getAttr(attr_name) orelse return null;
    if (!std.mem.eql(u8, attr.abstract.name, "builtin.integer")) return null;
    const int_attr = attr.cast(ir.Attribute.IntegerAttr) orelse return null;
    return int_attr.getValue();
}

fn tensorShapeAlloc(allocator: std.mem.Allocator, typ: ir.Type) !?[]i64 {
    const type_name = typ.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, type_name, dialect_mod.tensor_type_name)) return null;
    const key = typ.getDialectParamKey() orelse return null;
    const comma = std.mem.indexOfScalar(u8, key, ',') orelse return null;
    const dims_text = key[comma + 1 ..];
    if (dims_text.len == 0) return try allocator.alloc(i64, 0);

    var dim_count: usize = 1;
    for (dims_text) |ch| {
        if (ch == 'x') dim_count += 1;
    }

    const dims = try allocator.alloc(i64, dim_count);
    errdefer allocator.free(dims);
    var iter = std.mem.splitScalar(u8, dims_text, 'x');
    var index: usize = 0;
    while (iter.next()) |part| {
        if (part.len == 0 or index >= dim_count) {
            allocator.free(dims);
            return null;
        }
        const dim = std.fmt.parseInt(i64, part, 10) catch {
            allocator.free(dims);
            return null;
        };
        if (dim < 0) {
            allocator.free(dims);
            return null;
        }
        dims[index] = dim;
        index += 1;
    }
    if (index != dim_count) {
        allocator.free(dims);
        return null;
    }
    return dims;
}

fn isIdentityPermutation(values: []const i64) bool {
    for (values, 0..) |value, i| {
        if (value != @as(i64, @intCast(i))) return false;
    }
    return true;
}

const testing = std.testing;
const semantic = accy_choir.semantic;

fn findOpNamedInBlock(block: *ir.Block, name: []const u8) ?*ir.Operation {
    var iter = block.operations.head;
    while (iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (std.mem.eql(u8, op.name.name, name)) return op;
        iter = op.next_op;
    }
    return null;
}

test "canonicalization patterns publish Choir rewrite specs" {
    const allocator = testing.allocator;

    var patterns = rewrite.RewritePatternSet.init(allocator);
    defer patterns.deinit();

    try populateCanonicalizationPatterns(&patterns);

    try testing.expectEqual(canonicalization_pattern_entries.len, patterns.patterns.items.len);
    for (canonicalization_pattern_entries, patterns.patterns.items) |entry, pattern| {
        try testing.expectEqualStrings(entry.spec.name, pattern.spec.name);
        try testing.expectEqualStrings(entry.spec.root_op_name, pattern.spec.root_op_name);
        try testing.expectEqual(entry.spec.benefit, pattern.spec.benefit);
        try testing.expectEqual(entry.spec.kind, pattern.spec.kind);
        switch (entry.spec.products) {
            .none => {},
            else => return error.TestExpectedNoProducts,
        }
    }
    try testing.expectEqualStrings(AccyDialect.ReshapeOp.operation_name, canonicalization_pattern_entries[0].spec.root_op_name);
}

test "canonicalizeModule removes identity shape operations" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_2x3 = try builder.tensor(.f32, &.{ 2, 3 });
    var fb = try builder.beginFunction("identity_shapes", &.{f32_2x3}, &.{f32_2x3});
    const r0 = try fb.reshape(fb.parameter(0), f32_2x3, &.{ 2, 3 });
    const r1 = try fb.transpose(r0, f32_2x3, &.{ 0, 1 });
    const r2 = try fb.broadcast(r1, f32_2x3, &.{});
    const r3 = try fb.broadcastInDim(r2, f32_2x3, &.{ 2, 3 }, &.{ 0, 1 });
    const r4 = try fb.slice(r3, f32_2x3, &.{ 0, 0 }, &.{ 2, 3 }, &.{ 1, 1 });
    const r5 = try fb.concatenate(&.{r4}, f32_2x3, 0);
    try fb.return_(&.{r5});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(choir_mod, dialect_mod.AccyDialect.ReshapeOp.operation_name));
    try testing.expectEqual(@as(usize, 1), try canonicalizeModule(allocator, choir_mod, ctx));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(choir_mod, dialect_mod.AccyDialect.ReshapeOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(choir_mod, dialect_mod.AccyDialect.TransposeOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(choir_mod, dialect_mod.AccyDialect.BroadcastOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(choir_mod, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(choir_mod, dialect_mod.AccyDialect.SliceOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(choir_mod, dialect_mod.AccyDialect.ConcatenateOp.operation_name));

    const module_body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(module_body, "identity_shapes") orelse return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const ret = findOpNamedInBlock(entry, "func.return") orelse return error.TestExpectedReturn;
    try testing.expectEqual(entry.getArgument(0).?, ret.getOperand(0).?);
}

test "canonicalization pass preserves analyses when it makes no changes" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("canonicalize_add4", &.{ f32_4, f32_4 }, &.{f32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(canonicalizationPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "canonicalizeModule flattens shared-rhs batched dots" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 8, 2, 4 });
    const rhs_ty = try builder.tensor(.f32, &.{ 4, 3 });
    const out_ty = try builder.tensor(.f32, &.{ 8, 2, 3 });
    var fb = try builder.beginFunction("flatten_dot", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const product = try fb.dotGeneral(fb.parameter(0), fb.parameter(1), out_ty, &.{2}, &.{0}, &.{}, &.{});
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    _ = try canonicalizeModule(allocator, choir_mod, ctx);
    try testing.expectEqual(@as(usize, 2), ir.inspection.countOperationsNamed(choir_mod, dialect_mod.AccyDialect.ReshapeOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(choir_mod, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
}

test "canonicalization accounting reserves worker storage and closes actual identity rewrites" {
    const module = try accountingIdentityModule(testing.allocator);
    defer module.deinit();
    try checkCanonicalizationAccounting(module, 6);
}

fn checkCanonicalizationAccounting(module: *semantic.SemanticModule, rewrites: u64) !void {
    const revision = choir.product.revision;
    const allocator = testing.allocator;
    const selected = canonicalizationPass();
    const declared = try selected.work_contract.?.estimate(.{ .operation = module.choir_module });
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = .uniform(std.math.maxInt(u64)),
        .workspace = declared.workspace,
        .events = 16,
    }, &.{.{ .name = canonicalization_pass_name, .version = 1 }});
    defer ledger.destroy();
    var observed = testing.FailingAllocator.init(allocator, .{});
    var cache = try passes.AnalysisCache.initAccounted(observed.allocator(), null, ledger, .{}, 8);
    defer cache.deinit();
    var manager = passes.PassManager.init(observed.allocator());
    defer manager.deinit();
    try manager.addPass(selected);
    const before = observed.allocated_bytes;
    try testing.expectEqual(.success, manager.runWithAnalysisCache(
        module.choir_module,
        module.context(),
        &cache,
        .{ .max_threads = 1 },
    ));
    const worker_bytes = observed.allocated_bytes - before;
    try ledger.producersComplete();
    const receipt = ledger.view();
    try testing.expectEqual(1, receipt.executed.counters.pass_runs);
    try testing.expectEqual(@intFromBool(rewrites != 0), receipt.executed.counters.passes_modified);
    try testing.expectEqual(rewrites, receipt.executed.counters.successful_rewrites);
    const iterations: u64 = if (rewrites == 0) 1 else 2;
    try testing.expectEqual(iterations, receipt.executed.counters.rewrite_iterations);
    var pass_events: u32 = 0;
    for (receipt.events) |event| {
        if (event.phase != .pass) continue;
        pass_events += 1;
        try testing.expectEqual(declared.workspace, event.workspace);
        try testing.expect(event.workspace >= worker_bytes);
        try testing.expect(event.charged.allocation_capacity >= worker_bytes);
        try testing.expect(event.charged.rewrite_attempts >= rewrites);
    }
    try testing.expectEqual(1, pass_events);
    try module.verify();
}

fn accountingIdentityModule(allocator: std.mem.Allocator) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, .testing);
    defer builder.deinit();
    const typ = try builder.tensor(.f32, &.{ 2, 3 });
    var function = try builder.beginFunction("accounted_identity", &.{typ}, &.{typ});
    const reshape = try function.reshape(function.parameter(0), typ, &.{ 2, 3 });
    const transpose = try function.transpose(reshape, typ, &.{ 0, 1 });
    const broadcast = try function.broadcast(transpose, typ, &.{});
    const in_dim = try function.broadcastInDim(broadcast, typ, &.{ 2, 3 }, &.{ 0, 1 });
    const slice = try function.slice(in_dim, typ, &.{ 0, 0 }, &.{ 2, 3 }, &.{ 1, 1 });
    const concat = try function.concatenate(&.{slice}, typ, 0);
    try function.return_(&.{concat});
    try function.finish();
    const module = try builder.finish();
    return module;
}

test "canonicalization accounting refuses workspace and rewrite budgets before mutation" {
    inline for (.{ false, true }) |exhaust_workspace| {
        try checkCanonicalizationRefusal(exhaust_workspace);
    }
}

fn checkCanonicalizationRefusal(exhaust_workspace: bool) !void {
    const revision = choir.product.revision;
    const allocator = testing.allocator;
    const module = try accountingIdentityModule(allocator);
    defer module.deinit();
    const selected = canonicalizationPass();
    const declared = try selected.work_contract.?.estimate(.{ .operation = module.choir_module });
    try testing.expect(declared.workspace > 0);
    try testing.expect(declared.work.rewrite_attempts > 0);
    var allowance = revision.WorkVector.uniform(std.math.maxInt(u64));
    if (!exhaust_workspace) allowance.rewrite_attempts = declared.work.rewrite_attempts - 1;
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = allowance,
        .workspace = declared.workspace - @intFromBool(exhaust_workspace),
        .events = 16,
    }, &.{.{ .name = canonicalization_pass_name, .version = 1 }});
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 8);
    defer cache.deinit();
    var manager = passes.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(selected);
    try testing.expectEqual(.failure, manager.runWithAnalysisCache(
        module.choir_module,
        module.context(),
        &cache,
        .{ .max_threads = 1 },
    ));
    const receipt = ledger.view();
    try testing.expectEqual(.exhausted, receipt.outcome);
    try testing.expectEqual(0, receipt.executed.counters.pass_runs);
    try testing.expectEqual(0, receipt.executed.counters.passes_modified);
    try testing.expectEqual(0, receipt.executed.counters.successful_rewrites);
    try testing.expectEqual(0, receipt.executed.counters.rewrite_iterations);
    try testing.expectEqual(1, ir.inspection.countOperationsNamed(
        module.choir_module,
        AccyDialect.ReshapeOp.operation_name,
    ));
    try testing.expectError(error.WorkExhausted, ledger.producersComplete());
    try module.verify();
}

test "canonicalization accounting covers generated dots scans and broadcast chains" {
    const allocator = testing.allocator;
    const dot = try accountingDotModule(allocator);
    defer dot.deinit();
    try checkCanonicalizationAccounting(dot, 1);
    const scan = try accountingScanModule(allocator);
    defer scan.deinit();
    try checkCanonicalizationAccounting(scan, 1);
    for ([_]u32{ 0, 1, 4, 16 }) |depth| {
        const chain = try accountingBroadcastModule(allocator, depth);
        defer chain.deinit();
        try checkCanonicalizationAccounting(chain, if (depth == 0) 0 else 2 * depth - 1);
        try testing.expectEqual(@intFromBool(depth > 0), ir.inspection.countOperationsNamed(
            chain.choir_module,
            AccyDialect.BroadcastInDimOp.operation_name,
        ));
    }
}

fn accountingDotModule(allocator: std.mem.Allocator) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, .testing);
    defer builder.deinit();
    const lhs = try builder.tensor(.f32, &.{ 8, 2, 4 });
    const rhs = try builder.tensor(.f32, &.{ 4, 3 });
    const output = try builder.tensor(.f32, &.{ 8, 2, 3 });
    var function = try builder.beginFunction("accounted_dot", &.{ lhs, rhs }, &.{output});
    const value = try function.dotGeneral(
        function.parameter(0),
        function.parameter(1),
        output,
        &.{2},
        &.{0},
        &.{},
        &.{},
    );
    try function.return_(&.{value});
    try function.finish();
    return builder.finish();
}

fn accountingScanModule(allocator: std.mem.Allocator) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, .testing);
    defer builder.deinit();
    const typ = try builder.tensor(.f32, &.{16384});
    var function = try builder.beginFunction("accounted_scan", &.{typ}, &.{typ});
    const value = try function.cumsum(function.parameter(0), typ, 0);
    try function.return_(&.{value});
    try function.finish();
    return builder.finish();
}

fn accountingBroadcastModule(allocator: std.mem.Allocator, depth: u32) !*semantic.SemanticModule {
    std.debug.assert(depth <= 16);
    var builder = try semantic.Builder.init(allocator, .testing);
    defer builder.deinit();
    var dimensions: [17]i64 = @splat(2);
    dimensions[depth] = 1;
    const typ = try builder.tensor(.f32, &.{1});
    const output = try builder.tensor(.f32, dimensions[0 .. depth + 1]);
    var function = try builder.beginFunction("accounted_broadcast", &.{typ}, &.{output});
    var value = function.parameter(0);
    for (0..depth) |index| {
        const result = try builder.tensor(.f32, dimensions[depth - index - 1 .. depth + 1]);
        value = try function.broadcast(value, result, &.{2});
    }
    try function.return_(&.{value});
    try function.finish();
    return builder.finish();
}

test "canonicalization accounting refuses an unmodeled registered callback" {
    const allocator = testing.allocator;
    const module = try accountingIdentityModule(allocator);
    defer module.deinit();
    const extra = comptime [_]rewrite.RewritePattern{rewrite.RewritePattern.init(.{
        .name = "unmodeled-reshape",
        .root_op_name = AccyDialect.ReshapeOp.operation_name,
        .benefit = 20,
    }, unmodeledCanonicalization)};
    const registered = comptime rewrite.DialectCanonicalizationInterface.entryFor("accy", &extra);
    try module.context().registerDialectInterface("accy", registered);
    const ledger = try choir.product.revision.AccountingV1.create(allocator, .{
        .allowance = .uniform(std.math.maxInt(u64)),
        .workspace = 128 * 1024 * 1024,
        .events = 16,
    }, &.{.{ .name = canonicalization_pass_name, .version = 1 }});
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 8);
    defer cache.deinit();
    var manager = passes.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(canonicalizationPass());
    try testing.expectEqual(.failure, manager.runWithAnalysisCache(
        module.choir_module,
        module.context(),
        &cache,
        .{ .max_threads = 1 },
    ));
    try testing.expectEqual(.rejected, ledger.view().outcome);
    try testing.expect(ledger.view().missing_work_contract);
    try testing.expectEqual(0, ledger.view().executed.counters.pass_runs);
    try testing.expectEqual(0, ledger.view().executed.counters.successful_rewrites);
    try testing.expectEqual(1, ir.inspection.countOperationsNamed(
        module.choir_module,
        AccyDialect.ReshapeOp.operation_name,
    ));
}

fn unmodeledCanonicalization(_: *ir.Operation, _: *rewrite.PatternRewriter) rewrite.PatternResult {
    @panic("an unmodeled callback reached accounted work");
}

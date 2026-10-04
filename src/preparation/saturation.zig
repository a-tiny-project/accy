const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const dialect_mod = accy_choir.dialect;
const semantic = accy_choir.semantic;

const ir = choir.ir;
const passes = choir.passes;
const work = passes.pass.work;
const saturation_options = passes.saturation.OptimizationOptions{
    .candidate = isSaturationCandidate,
};

pub const saturation_pass_name = "accy-choir-saturate";
pub const saturation_pass_description =
    "Saturate block-local Accy Choir tensor operations with dedup and algebraic identities";

/// The tensor stage adds this pass to simplify tensor operations with algebraic identities and
/// duplicate removal inside each block. The function returns the pass, with its name, description
/// and a work contract, a pass's declared name, version and cost estimate, at version 1. Every
/// rewrite keeps finite values, the sign of zero, infinities and which values are NaN unchanged.
/// The bits inside a NaN and the floating-point status flags are outside what the pass promises.
/// Removing a multiplication by an identity matrix applies to integer types alone, because a
/// floating multiplication by zero can give NaN and a floating sum can change the sign of zero. A
/// backend's precision tier gives no license for looser algebraic rewrites.
pub fn tensorSaturationPass() passes.Pass {
    return .{
        .name = saturation_pass_name,
        .description = saturation_pass_description,
        .run_fn = runTensorSaturationPass,
        .work_contract = .{
            .identity = .{ .name = saturation_pass_name, .version = 1 },
            .estimate = saturationWork,
        },
    };
}

/// The compile chain calls this before the pass runs, to charge its cost against the caller's
/// limits. Every rule merges a value with one of its existing operands or with an ancestor through
/// single-input operations, and removing duplicates keeps each operation's cost. So a cheaper form
/// for the earliest value in a class, the set of forms the pass knows to be equal to one value, can
/// only be a cycle of single-input identities, and a dot product costs the most and is never the
/// cheaper form. Picking the cheapest form may walk that cycle, and it adds no new operation or
/// class. The bound comes from the shared elimination bound for this pass's nine rules and its
/// iteration limit.
fn saturationWork(input: work.Input) !work.Bounds {
    return passes.saturation.eliminationWorkBound(
        input,
        tensor_rules.len,
        saturation_options.max_iterations,
    );
}

const AccountingRefusal = enum { workspace, rewrites };

fn checkSaturationAccounting(depth: u32, refusal: ?AccountingRefusal, computed: bool) !void {
    const allocator = std.testing.allocator;
    const revision = choir.product.revision;
    var builder = try semantic.Builder.init(allocator, .testing);
    defer builder.deinit();
    const typ = try builder.tensor(.f32, &.{ 2, 3 });
    var function = try builder.beginFunction("saturation_accounting", &.{typ}, &.{typ});
    var value = if (computed)
        try function.add(function.parameter(0), function.parameter(0))
    else
        function.parameter(0);
    for (0..depth) |_| value = try function.reshape(value, typ, &.{ 2, 3 });
    try function.return_(&.{value});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    const selected = tensorSaturationPass();
    const declared = try selected.work_contract.?.estimate(.{ .operation = module.choir_module });
    var allowance = revision.WorkVector.uniform(std.math.maxInt(u64));
    if (refusal == .rewrites) allowance.rewrite_attempts = declared.work.rewrite_attempts - 1;
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = allowance,
        .workspace = declared.workspace - @intFromBool(refusal == .workspace),
        .events = 16,
    }, &.{.{ .name = saturation_pass_name, .version = 1 }});
    defer ledger.destroy();
    var observed = std.testing.FailingAllocator.init(allocator, .{});
    var cache = try passes.AnalysisCache.initAccounted(observed.allocator(), null, ledger, .{}, 8);
    defer cache.deinit();
    var manager = passes.PassManager.init(observed.allocator());
    defer manager.deinit();
    try manager.addPass(selected);
    const before = observed.allocated_bytes;
    const result = manager.runWithAnalysisCache(
        module.choir_module,
        module.context(),
        &cache,
        .{ .max_threads = 1 },
    );
    const executed = observed.allocated_bytes - before;
    const receipt = ledger.view();
    const remaining = ir.inspection.countOperationsNamed(
        module.choir_module,
        dialect_mod.AccyDialect.ReshapeOp.operation_name,
    );
    if (refusal != null) {
        try std.testing.expectEqual(.failure, result);
        try std.testing.expectEqual(.exhausted, receipt.outcome);
        try std.testing.expectEqual(0, receipt.executed.counters.pass_runs);
        try std.testing.expectEqual(depth, remaining);
        try std.testing.expectError(error.WorkExhausted, ledger.producersComplete());
    } else {
        try std.testing.expectEqual(.success, result);
        try ledger.producersComplete();
        try std.testing.expectEqual(1, receipt.executed.counters.pass_runs);
        try std.testing.expectEqual(0, remaining);
        try std.testing.expect(executed <= declared.workspace);
        try std.testing.expect(executed <= receipt.charged.allocation_capacity);
    }
    try module.verify();
}

pub fn saturateTensorOperations(
    allocator: std.mem.Allocator,
    choir_module: *ir.Operation,
    ctx: *ir.Context,
) !passes.saturation.OptimizationStats {
    var rules = choir.egraph.RewriteSet.init(allocator);
    defer rules.deinit();
    try populateTensorRules(&rules);

    const stats = try passes.runEGraphOptimization(
        allocator,
        ctx,
        choir_module,
        &rules,
        saturation_options,
    );
    return stats;
}

pub fn populateTensorRules(rules: *choir.egraph.RewriteSet) !void {
    rules.setCostModel(tensorCostModel());
    for (tensor_rules) |rule| {
        try rules.add(.{
            .name = rule.name,
            .benefit = rule.benefit,
            .apply = rule.apply,
        });
    }
}

fn runTensorSaturationPass(pass_ctx: *passes.PassContext) passes.PassResult {
    const stats = saturateTensorOperations(
        pass_ctx.allocator,
        pass_ctx.op,
        pass_ctx.ir_ctx,
    ) catch return .failure;
    if (stats.replacements == 0) {
        pass_ctx.preserveAllAnalyses();
    } else {
        pass_ctx.markModified();
    }
    if (!passes.saturation.observeOptimization(pass_ctx, stats)) return .failure;
    return .success;
}

fn isSaturationCandidate(_: ?*anyopaque, op: *ir.Operation) anyerror!bool {
    if (op.getNumResults() != 1) return false;
    return std.mem.eql(u8, op.name.getDialectNamespace(), "accy");
}

const TensorRule = struct {
    name: []const u8,
    benefit: u32,
    apply: choir.egraph.RewriteFn,
};

const tensor_rules = [_]TensorRule{
    .{ .name = "accy-transpose-identity", .benefit = 20, .apply = transposeIdentity },
    .{ .name = "accy-reshape-identity", .benefit = 20, .apply = reshapeIdentity },
    .{ .name = "accy-broadcast-identity", .benefit = 20, .apply = broadcastIdentity },
    .{ .name = "accy-broadcast-in-dim-identity", .benefit = 20, .apply = broadcastInDimIdentity },
    .{ .name = "accy-convert-identity", .benefit = 15, .apply = convertIdentity },
    .{ .name = "accy-dot-right-identity", .benefit = 14, .apply = dotRightIdentity },
    .{ .name = "accy-dot-left-identity", .benefit = 14, .apply = dotLeftIdentity },
    .{ .name = "accy-convert-round-trip", .benefit = 12, .apply = convertRoundTrip },
    .{ .name = "accy-transpose-involution", .benefit = 10, .apply = transposeInvolution },
};

fn tensorCostModel() choir.egraph.CostModel {
    const AccyDialect = dialect_mod.AccyDialect;
    return .{
        .operation = 8,
        .constant = 1,
        .constant_op_name = AccyDialect.ConstantOp.operation_name,
        .overrides = &.{
            .{ .name = AccyDialect.ReshapeOp.operation_name, .cost = 1 },
            .{ .name = AccyDialect.BroadcastOp.operation_name, .cost = 1 },
            .{ .name = AccyDialect.BroadcastInDimOp.operation_name, .cost = 1 },
            .{ .name = AccyDialect.TransposeOp.operation_name, .cost = 1 },
            .{ .name = AccyDialect.ConvertOp.operation_name, .cost = 2 },
            .{ .name = AccyDialect.ReduceOp.operation_name, .cost = 12 },
            .{ .name = AccyDialect.DotGeneralOp.operation_name, .cost = 32 },
        },
    };
}

fn transposeIdentity(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    entry_node: *const choir.egraph.Node,
) anyerror!bool {
    const transpose_name = dialect_mod.AccyDialect.TransposeOp.operation_name;
    if (!isOperation(entry_node, transpose_name)) return false;
    const permutation = i64ListAttr(entry_node, "permutation") orelse return false;
    if (entry_node.result_types.len != 1) return false;
    if ((tensorRank(entry_node.result_types[0]) orelse return false) != permutation.len) {
        return false;
    }
    if (!isIdentityIndexList(permutation)) return false;
    return try mergeUnaryWithOperand(ctx, class, entry_node);
}

fn reshapeIdentity(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    entry_node: *const choir.egraph.Node,
) anyerror!bool {
    const reshape_name = dialect_mod.AccyDialect.ReshapeOp.operation_name;
    if (!isOperation(entry_node, reshape_name)) return false;
    const new_shape = i64ListAttr(entry_node, "new_shape") orelse return false;
    if (!resultTypeShapeMatches(entry_node, new_shape)) return false;
    return try mergeUnaryWithOperand(ctx, class, entry_node);
}

fn broadcastIdentity(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    entry_node: *const choir.egraph.Node,
) anyerror!bool {
    const broadcast_name = dialect_mod.AccyDialect.BroadcastOp.operation_name;
    if (!isOperation(entry_node, broadcast_name)) return false;
    const sizes = i64ListAttr(entry_node, "sizes") orelse return false;
    if (sizes.len != 0) return false;
    return try mergeUnaryWithOperand(ctx, class, entry_node);
}

fn broadcastInDimIdentity(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    entry_node: *const choir.egraph.Node,
) anyerror!bool {
    const broadcast_name = dialect_mod.AccyDialect.BroadcastInDimOp.operation_name;
    if (!isOperation(entry_node, broadcast_name)) return false;
    const dims = i64ListAttr(entry_node, "broadcast_dims") orelse return false;
    const result_shape = i64ListAttr(entry_node, "result_shape") orelse return false;
    if (dims.len != result_shape.len) return false;
    if (!resultTypeShapeMatches(entry_node, result_shape)) return false;
    if (!isIdentityIndexList(dims)) return false;
    return try mergeUnaryWithOperand(ctx, class, entry_node);
}

fn convertIdentity(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    entry_node: *const choir.egraph.Node,
) anyerror!bool {
    const convert_name = dialect_mod.AccyDialect.ConvertOp.operation_name;
    if (!isOperation(entry_node, convert_name)) return false;
    _ = entry_node.getAttr("convert_to") orelse return false;
    return try mergeUnaryWithOperand(ctx, class, entry_node);
}

fn convertRoundTrip(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    entry_node: *const choir.egraph.Node,
) anyerror!bool {
    const convert_name = dialect_mod.AccyDialect.ConvertOp.operation_name;
    if (!isOperation(entry_node, convert_name)) return false;
    if (entry_node.operands.len != 1) return false;
    if (entry_node.result_types.len != 1) return false;
    const source_dtype = tensorDType(entry_node.result_types[0]) orelse return false;
    for (ctx.nodes(entry_node.operands[0])) |*inner_node| {
        if (!isOperation(inner_node, convert_name)) continue;
        if (inner_node.operands.len != 1) continue;
        if (inner_node.result_types.len != 1) continue;
        const intermediate_dtype = tensorDType(inner_node.result_types[0]) orelse continue;
        if (!losslessRoundTripVia(source_dtype, intermediate_dtype)) continue;
        if (!classHasType(ctx, inner_node.operands[0], entry_node.result_types[0])) continue;
        return try ctx.merge(class, inner_node.operands[0]);
    }
    return false;
}

fn dotRightIdentity(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    entry_node: *const choir.egraph.Node,
) anyerror!bool {
    if (!standardMatrixProductDot(entry_node)) return false;
    if (entry_node.operands.len != 2) return false;
    if (entry_node.result_types.len != 1) return false;
    const result_shape = tensorMatrixShape(entry_node.result_types[0]) orelse return false;
    const dtype = tensorDType(entry_node.result_types[0]) orelse return false;
    if (!classHasType(ctx, entry_node.operands[0], entry_node.result_types[0])) return false;
    for (ctx.nodes(entry_node.operands[1])) |*rhs_node| {
        if (!isIdentityMatrixConstant(rhs_node, dtype, result_shape[1])) continue;
        return try ctx.merge(class, entry_node.operands[0]);
    }
    return false;
}

fn dotLeftIdentity(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    entry_node: *const choir.egraph.Node,
) anyerror!bool {
    if (!standardMatrixProductDot(entry_node)) return false;
    if (entry_node.operands.len != 2) return false;
    if (entry_node.result_types.len != 1) return false;
    const result_shape = tensorMatrixShape(entry_node.result_types[0]) orelse return false;
    const dtype = tensorDType(entry_node.result_types[0]) orelse return false;
    if (!classHasType(ctx, entry_node.operands[1], entry_node.result_types[0])) return false;
    for (ctx.nodes(entry_node.operands[0])) |*lhs_node| {
        if (!isIdentityMatrixConstant(lhs_node, dtype, result_shape[0])) continue;
        return try ctx.merge(class, entry_node.operands[1]);
    }
    return false;
}

fn transposeInvolution(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    entry_node: *const choir.egraph.Node,
) anyerror!bool {
    const transpose_name = dialect_mod.AccyDialect.TransposeOp.operation_name;
    if (!isOperation(entry_node, transpose_name)) return false;
    if (entry_node.operands.len != 1) return false;
    if (entry_node.result_types.len != 1) return false;
    const outer = i64ListAttr(entry_node, "permutation") orelse return false;

    for (ctx.nodes(entry_node.operands[0])) |*inner_node| {
        if (!isOperation(inner_node, transpose_name)) continue;
        if (inner_node.operands.len != 1) continue;
        const inner = i64ListAttr(inner_node, "permutation") orelse continue;
        if (!composesToIdentity(inner, outer)) continue;
        if (!classHasType(ctx, inner_node.operands[0], entry_node.result_types[0])) continue;
        return try ctx.merge(class, inner_node.operands[0]);
    }
    return false;
}

fn mergeUnaryWithOperand(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    entry_node: *const choir.egraph.Node,
) anyerror!bool {
    if (entry_node.operands.len != 1) return false;
    if (entry_node.result_types.len != 1) return false;
    if (!classHasType(ctx, entry_node.operands[0], entry_node.result_types[0])) return false;
    return try ctx.merge(class, entry_node.operands[0]);
}

fn isOperation(node: *const choir.egraph.Node, name: []const u8) bool {
    return node.kind == .operation and std.mem.eql(u8, node.op_name, name);
}

fn i64ListAttr(node: *const choir.egraph.Node, name: []const u8) ?[]align(1) const i64 {
    const attr = node.getAttr(name) orelse return null;
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
    if (dialect_attr.payload.len % @sizeOf(i64) != 0) return null;
    return std.mem.bytesAsSlice(i64, dialect_attr.payload);
}

fn isIdentityIndexList(indices: []align(1) const i64) bool {
    for (indices, 0..) |index, position| {
        if (index != @as(i64, @intCast(position))) return false;
    }
    return true;
}

fn resultTypeShapeMatches(entry_node: *const choir.egraph.Node, shape: []align(1) const i64) bool {
    if (entry_node.result_types.len != 1) return false;
    return tensorShapeMatches(entry_node.result_types[0], shape);
}

fn tensorShapeMatches(typ: ir.Type, expected: []align(1) const i64) bool {
    const type_name = typ.getDialectTypeName() orelse return false;
    if (!std.mem.eql(u8, type_name, dialect_mod.tensor_type_name)) return false;
    const dims_text = tensorDimsText(typ) orelse return false;
    if (expected.len == 0) return dims_text.len == 0;
    var iter = std.mem.splitScalar(u8, dims_text, 'x');
    var index: usize = 0;
    while (iter.next()) |part| {
        if (part.len == 0) return false;
        if (index >= expected.len) return false;
        const dim = std.fmt.parseInt(i64, part, 10) catch return false;
        if (dim != expected[index]) return false;
        index += 1;
    }
    return index == expected.len;
}

fn tensorRank(typ: ir.Type) ?usize {
    const type_name = typ.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, type_name, dialect_mod.tensor_type_name)) return null;
    const dims_text = tensorDimsText(typ) orelse return null;
    if (dims_text.len == 0) return 0;
    var iter = std.mem.splitScalar(u8, dims_text, 'x');
    var rank: usize = 0;
    while (iter.next()) |part| {
        if (part.len == 0) return null;
        _ = std.fmt.parseInt(i64, part, 10) catch return null;
        rank += 1;
    }
    return rank;
}

fn tensorDimsText(typ: ir.Type) ?[]const u8 {
    const key = typ.getDialectParamKey() orelse return null;
    const comma = std.mem.indexOfScalar(u8, key, ',') orelse return null;
    return key[comma + 1 ..];
}

fn tensorDType(typ: ir.Type) ?gpu_abi.DType {
    const type_name = typ.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, type_name, dialect_mod.tensor_type_name)) return null;
    const key = typ.getDialectParamKey() orelse return null;
    const comma = std.mem.indexOfScalar(u8, key, ',') orelse return null;
    return gpu_abi.DType.fromName(key[0..comma]);
}

fn losslessRoundTripVia(source: gpu_abi.DType, intermediate: gpu_abi.DType) bool {
    if (source == intermediate) return true;
    if (source.isFloat() or intermediate.isFloat()) {
        return losslessFloatRoundTripVia(source, intermediate);
    }
    if (source.isSignedInt()) {
        return intermediate.isSignedInt() and intBits(intermediate) >= intBits(source);
    }
    if (source.isUnsignedInt()) {
        if (intermediate.isUnsignedInt()) return intBits(intermediate) >= intBits(source);
        if (intermediate.isSignedInt()) return intBits(intermediate) > intBits(source);
    }
    return false;
}

fn losslessFloatRoundTripVia(source: gpu_abi.DType, intermediate: gpu_abi.DType) bool {
    return switch (source) {
        .f16, .bf16 => intermediate == .f32 or intermediate == .f64,
        .f32 => intermediate == .f64,
        else => false,
    };
}

fn intBits(dtype: gpu_abi.DType) u16 {
    return switch (dtype) {
        .i1 => 1,
        .i8, .u8 => 8,
        .i16, .u16 => 16,
        .i32, .u32 => 32,
        .i64, .u64 => 64,
        else => 0,
    };
}

fn standardMatrixProductDot(node: *const choir.egraph.Node) bool {
    const dot_name = dialect_mod.AccyDialect.DotGeneralOp.operation_name;
    if (!isOperation(node, dot_name)) return false;
    if (node.operands.len != 2) return false;
    const lhs_batch = i64ListAttr(node, "lhs_batch") orelse return false;
    const rhs_batch = i64ListAttr(node, "rhs_batch") orelse return false;
    const lhs_contract = i64ListAttr(node, "lhs_contract") orelse return false;
    const rhs_contract = i64ListAttr(node, "rhs_contract") orelse return false;
    return lhs_batch.len == 0 and
        rhs_batch.len == 0 and
        i64ListEquals(lhs_contract, &[_]i64{1}) and
        i64ListEquals(rhs_contract, &[_]i64{0});
}

fn i64ListEquals(lhs: []align(1) const i64, rhs: []const i64) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (left != right) return false;
    }
    return true;
}

fn tensorMatrixShape(typ: ir.Type) ?[2]usize {
    const type_name = typ.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, type_name, dialect_mod.tensor_type_name)) return null;
    const dims_text = tensorDimsText(typ) orelse return null;
    var iter = std.mem.splitScalar(u8, dims_text, 'x');
    const rows_text = iter.next() orelse return null;
    const cols_text = iter.next() orelse return null;
    if (iter.next() != null) return null;
    if (rows_text.len == 0 or cols_text.len == 0) return null;
    const rows = std.fmt.parseInt(i64, rows_text, 10) catch return null;
    const cols = std.fmt.parseInt(i64, cols_text, 10) catch return null;
    if (rows <= 0 or cols <= 0) return null;
    return .{ @intCast(rows), @intCast(cols) };
}

fn isIdentityMatrixConstant(node: *const choir.egraph.Node, dtype: gpu_abi.DType, n: usize) bool {
    const constant_name = dialect_mod.AccyDialect.ConstantOp.operation_name;
    if (!isOperation(node, constant_name)) return false;
    if (n == 0) return false;
    if (node.result_types.len != 1) return false;
    const node_dtype = tensorDType(node.result_types[0]) orelse return false;
    if (node_dtype != dtype) return false;
    const shape = tensorMatrixShape(node.result_types[0]) orelse return false;
    if (shape[0] != n or shape[1] != n) return false;
    const payload = constantPayload(node) orelse return false;
    return identityPayloadMatchesDType(dtype, payload, n);
}

fn constantPayload(node: *const choir.egraph.Node) ?[]const u8 {
    const attr = node.getAttr("payload") orelse return null;
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
    return dialect_attr.payload;
}

fn identityPayloadMatchesDType(dtype: gpu_abi.DType, payload: []const u8, n: usize) bool {
    return switch (dtype) {
        .i1 => false,
        .i8 => identityPayloadMatches(i8, payload, n, 0, 1),
        .i16 => identityPayloadMatches(i16, payload, n, 0, 1),
        .i32 => identityPayloadMatches(i32, payload, n, 0, 1),
        .i64 => identityPayloadMatches(i64, payload, n, 0, 1),
        .u8 => identityPayloadMatches(u8, payload, n, 0, 1),
        .u16 => identityPayloadMatches(u16, payload, n, 0, 1),
        .u32 => identityPayloadMatches(u32, payload, n, 0, 1),
        .u64 => identityPayloadMatches(u64, payload, n, 0, 1),
        .f16, .bf16, .f32, .f64, .key => false,
    };
}

fn identityPayloadMatches(comptime T: type, payload: []const u8, n: usize, zero: T, one: T) bool {
    const value_count = std.math.mul(usize, n, n) catch return false;
    const expected_len = std.math.mul(usize, value_count, @sizeOf(T)) catch return false;
    if (payload.len != expected_len) return false;
    const values = std.mem.bytesAsSlice(T, payload);
    for (0..n) |row| {
        for (0..n) |col| {
            const expected = if (row == col) one else zero;
            if (values[row * n + col] != expected) return false;
        }
    }
    return true;
}

fn composesToIdentity(inner: []align(1) const i64, outer: []align(1) const i64) bool {
    if (inner.len != outer.len) return false;
    for (outer, 0..) |outer_index, position| {
        if (outer_index < 0) return false;
        const index: usize = @intCast(outer_index);
        if (index >= inner.len) return false;
        if (inner[index] != @as(i64, @intCast(position))) return false;
    }
    return true;
}

fn classHasType(
    ctx: *choir.egraph.RewriteContext,
    class: choir.egraph.ClassId,
    expected: ir.Type,
) bool {
    for (ctx.nodes(class)) |*candidate| {
        switch (candidate.kind) {
            .value => if (candidate.value.?.type.eql(expected)) return true,
            .operation => {
                if (candidate.result_types.len != 1) continue;
                if (candidate.result_types[0].eql(expected)) return true;
            },
        }
    }
    return false;
}

const testing = std.testing;

fn findOpNamedInBlock(block: *ir.Block, name: []const u8) ?*ir.Operation {
    var iter = block.operations.head;
    while (iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (std.mem.eql(u8, op.name.name, name)) return op;
        iter = op.next_op;
    }
    return null;
}

fn writeIdentityI32(values: []i32, n: usize) void {
    for (0..n) |row| {
        for (0..n) |col| {
            values[row * n + col] = if (row == col) 1 else 0;
        }
    }
}

fn expectFloatingIdentityRetained(comptime T: type, dtype: gpu_abi.DType, one: T) !void {
    const allocator = testing.allocator;
    const payload = [_]T{ one, 0, 0, one };
    for ([_]bool{ false, true }) |identity_on_left| {
        var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
        defer builder.deinit();
        const ty = try builder.tensor(dtype, &.{ 2, 2 });
        var fb = try builder.beginFunction("floating_identity", &.{ty}, &.{ty});
        const identity = try fb.constant(ty, std.mem.sliceAsBytes(&payload));
        const lhs = if (identity_on_left) identity else fb.parameter(0);
        const rhs = if (identity_on_left) fb.parameter(0) else identity;
        const product = try fb.dotGeneral(lhs, rhs, ty, &.{1}, &.{0}, &.{}, &.{});
        try fb.return_(&.{product});
        try fb.finish();
        const module = try builder.finish();
        defer module.deinit();
        _ = try saturateTensorOperations(allocator, module.choir_module, module.context());
        try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(
            module.choir_module,
            dialect_mod.AccyDialect.DotGeneralOp.operation_name,
        ));
        try module.verify();
    }
}

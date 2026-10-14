const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const canonicalization = @import("canonicalization.zig");
const dialect_mod = accy_choir.dialect;
const shape_analysis = @import("shape/root.zig");

const ir = choir.ir;
const rewrite = ir.rewrite;
const passes = choir.passes;
const work = passes.pass.work;
const DType = gpu_abi.DType;

pub const constant_folding_pass_name = "accy-choir-constant-fold";
pub const constant_folding_pass_description =
    "Fold Accy Choir operations with constant operands";

pub fn constantFoldingPass() passes.Pass {
    return .{
        .name = constant_folding_pass_name,
        .description = constant_folding_pass_description,
        .run_fn = runConstantFoldingPass,
        .work_contract = .{
            .identity = .{ .name = constant_folding_pass_name, .version = 1 },
            .estimate = foldingWork,
        },
    };
}

const FoldWork = struct {
    candidates: u64 = 0,
    payload: u64 = 0,
    shape_key: u64 = 0,
    list_bytes: u64 = 0,
    broadcasts: bool = false,

    fn visit(self: *FoldWork, op: *ir.Operation) !ir.WalkResult {
        const name = op.name.name;
        const broadcast = std.mem.eql(
            u8,
            name,
            dialect_mod.AccyDialect.BroadcastInDimOp.operation_name,
        );
        const reshape = std.mem.eql(u8, name, dialect_mod.AccyDialect.ReshapeOp.operation_name);
        if (broadcast or reshape or binaryFoldKind(name) != null or unaryFoldKind(name) != null) {
            self.candidates = try work.add(self.candidates, 1);
        }
        self.broadcasts = self.broadcasts or broadcast;
        if (std.mem.eql(u8, name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
            if ((dialect_mod.AccyDialect.ConstantOp{ .op = op }).getPayload()) |payload| {
                self.payload = @max(self.payload, payload.len);
            }
        }
        for (op.results.items) |*result| {
            if (result.type.getDialectParamKey()) |key| {
                self.shape_key = @max(self.shape_key, key.len);
            }
        }
        for (op.getOperandValues()) |operand| {
            if (operand.type.getDialectParamKey()) |key| {
                self.shape_key = @max(self.shape_key, key.len);
            }
        }
        if (broadcast) {
            if (op.getAttr("broadcast_dims")) |attr| {
                if (attr.cast(ir.Attribute.DialectAttr)) |value| {
                    self.list_bytes = try work.add(self.list_bytes, value.payload.len);
                }
            }
        }
        return .advance;
    }
};

fn foldingWork(input: work.Input) !work.Bounds {
    const counts = try work.Census.inspect(input.operation);
    var facts: FoldWork = .{};
    _ = try input.operation.walk(.{ .order = .pre_order }, &facts, FoldWork.visit);
    const payload = @max(facts.payload, if (facts.broadcasts) broadcast_fold_payload_limit else 0);
    const payload_bytes = try work.multiply(facts.candidates, payload);
    const dimensions = try work.multiply(facts.shape_key, @sizeOf(usize));
    const per_fold = try work.add(try work.add(payload, dimensions), 2 * @alignOf(usize));
    const queues = try work.multiply(2, try work.arrayListGrowth(*ir.Operation, facts.candidates));
    const temporary = try work.add(facts.list_bytes, try work.multiply(facts.candidates, per_fold));
    const bytes = try work.add(queues, temporary);
    const visits = try work.add(counts.atoms, counts.input_bytes);
    const uses = try work.add(try work.add(counts.values, counts.operands), 1);
    const traversal = try work.multiply(64, try work.multiply(try work.add(visits, 1), uses));
    const processing = try work.multiply(16, try work.multiply(
        payload_bytes,
        try work.add(facts.shape_key, 1),
    ));
    const nodes = try work.multiply(
        facts.candidates,
        @sizeOf(ir.Operation) + @sizeOf(ir.Value) + 64,
    );
    return .{
        .work = .{
            .input_bytes = counts.input_bytes,
            .output_bytes = try work.add(payload_bytes, nodes),
            .structural_visits = try work.add(traversal, processing),
            .allocation_capacity = bytes,
        },
        .workspace = bytes,
    };
}

fn runConstantFoldingPass(pass_ctx: *passes.PassContext) passes.PassResult {
    const analysis = shape_analysis.getShapeLayoutAnalysis(
        pass_ctx,
        pass_ctx.op,
    ) catch return .failure;

    var rewriter = rewrite.PatternRewriter.init(pass_ctx.allocator, pass_ctx.ir_ctx);
    defer rewriter.deinit();

    var folded_count: usize = 0;
    foldOnOp(
        pass_ctx.ir_ctx,
        pass_ctx.op,
        analysis,
        &rewriter,
        &folded_count,
    ) catch return .failure;
    if (folded_count == 0) {
        pass_ctx.preserveAllAnalyses();
    } else {
        rewriter.finalize(pass_ctx.op);
        pass_ctx.markModified();
    }
    return .success;
}

fn foldOnOp(
    ctx: *ir.Context,
    op: *ir.Operation,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    rewriter: *rewrite.PatternRewriter,
    folded_count: *usize,
) !void {
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                const next = current_op.next_op;
                if (current_op.regions.items.len > 0) {
                    try foldOnOp(ctx, current_op, analysis, rewriter, folded_count);
                }
                if (try foldOp(ctx, current_op, analysis, rewriter)) {
                    folded_count.* += 1;
                }
                current = next;
            }
        }
    }
}

fn foldOp(
    ctx: *ir.Context,
    op: *ir.Operation,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    if (try foldReshapeConstant(ctx, op, analysis, rewriter)) return true;
    if (try foldBroadcastInDimConstant(ctx, op, analysis, rewriter)) return true;
    if (try foldElementwiseConstant(ctx, op, analysis, rewriter)) return true;
    return false;
}

const broadcast_fold_payload_limit: usize = 64 * 1024;

fn foldBroadcastInDimConstant(
    ctx: *ir.Context,
    op: *ir.Operation,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    if (!std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name)) {
        return false;
    }
    if (op.getNumOperands() != 1 or op.getNumResults() != 1) return false;

    const input = op.getOperand(0) orelse return false;
    const result = op.getResult(0) orelse return false;
    const input_const = constantDefiningOp(input) orelse return false;
    const input_info = analysis.get(input) orelse return false;
    const result_info = analysis.get(result) orelse return false;

    if (input_info.dtype != result_info.dtype) return false;
    const input_bytes = expectedPayloadBytes(input_info) orelse return false;
    const result_bytes = expectedPayloadBytes(result_info) orelse return false;
    if (result_bytes > broadcast_fold_payload_limit) return false;

    const payload = (dialect_mod.AccyDialect.ConstantOp{ .op = input_const }).getPayload() orelse
        return false;
    if (payload.len != input_bytes) return false;

    const broadcast_dims = (try canonicalization.readI64ListAttrAlloc(
        rewriter.allocator,
        op,
        "broadcast_dims",
        dialect_mod.AccyDialect.BroadcastInDimOp.dialectAttrName("broadcast_dims"),
    )) orelse return false;
    defer rewriter.allocator.free(broadcast_dims);
    if (broadcast_dims.len != input_info.dims.len) return false;
    for (broadcast_dims) |mapped| {
        if (mapped < 0 or @as(usize, @intCast(mapped)) >= result_info.dims.len) return false;
    }

    const folded_payload = (try foldBroadcastPayload(
        rewriter.allocator,
        result_info.dtype,
        payload,
        input_info.dims,
        result_info.dims,
        broadcast_dims,
    )) orelse return false;
    defer rewriter.allocator.free(folded_payload);

    const folded = try createConstantBefore(ctx, rewriter, op, folded_payload, result.type);
    try rewriter.replaceOpWithValue(op, folded.getResult());
    return true;
}

fn foldBroadcastPayload(
    allocator: std.mem.Allocator,
    dtype: DType,
    input_payload: []const u8,
    input_dims: []const i64,
    result_dims: []const i64,
    broadcast_dims: []const i64,
) !?[]u8 {
    const element_size: usize = dtype.sizeOf();
    var result_elements: usize = 1;
    for (result_dims) |dim| {
        if (dim < 0) return null;
        result_elements = std.math.mul(usize, result_elements, @intCast(dim)) catch return null;
    }

    const out = try allocator.alloc(u8, result_elements * element_size);
    errdefer allocator.free(out);

    const coords = try allocator.alloc(usize, result_dims.len);
    defer allocator.free(coords);
    @memset(coords, 0);

    var out_index: usize = 0;
    while (out_index < result_elements) : (out_index += 1) {
        var in_index: usize = 0;
        for (input_dims, broadcast_dims) |in_dim, mapped| {
            if (in_dim < 0) return null;
            const extent: usize = @intCast(in_dim);
            const coord = if (extent <= 1) 0 else coords[@intCast(mapped)];
            in_index = in_index * extent + coord;
        }
        @memcpy(
            out[out_index * element_size ..][0..element_size],
            input_payload[in_index * element_size ..][0..element_size],
        );

        var axis = result_dims.len;
        while (axis > 0) {
            axis -= 1;
            coords[axis] += 1;
            if (coords[axis] < @as(usize, @intCast(result_dims[axis]))) break;
            coords[axis] = 0;
        }
    }
    return out;
}

fn foldReshapeConstant(
    ctx: *ir.Context,
    op: *ir.Operation,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    if (!std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.ReshapeOp.operation_name)) {
        return false;
    }
    if (op.getNumOperands() != 1 or op.getNumResults() != 1) return false;

    const input = op.getOperand(0) orelse return false;
    const result = op.getResult(0) orelse return false;
    const input_const = constantDefiningOp(input) orelse return false;
    const input_info = analysis.get(input) orelse return false;
    const result_info = analysis.get(result) orelse return false;

    if (!input_info.hasStaticLayout() or !result_info.hasStaticLayout()) return false;
    if (input_info.dtype != result_info.dtype) return false;
    if (input_info.element_count.? != result_info.element_count.?) return false;

    const payload = (dialect_mod.AccyDialect.ConstantOp{ .op = input_const }).getPayload() orelse
        return false;
    const expected_bytes = std.math.mul(
        u64,
        result_info.element_count.?,
        @as(u64, result_info.dtype.sizeOf()),
    ) catch return false;
    if (expected_bytes != payload.len) return false;

    const folded = try createConstantBefore(ctx, rewriter, op, payload, result.type);
    try rewriter.replaceOpWithValue(op, folded.getResult());
    return true;
}

const BinaryFoldKind = enum {
    add,
    sub,
    mul,
};

const UnaryFoldKind = enum {
    neg,
    floor,
    round,
    trunc,
};

fn foldElementwiseConstant(
    ctx: *ir.Context,
    op: *ir.Operation,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    rewriter: *rewrite.PatternRewriter,
) !bool {
    if (binaryFoldKind(op.name.name)) |kind| {
        return foldBinaryElementwiseConstant(ctx, op, analysis, rewriter, kind);
    }
    if (unaryFoldKind(op.name.name)) |kind| {
        return foldUnaryElementwiseConstant(ctx, op, analysis, rewriter, kind);
    }
    return false;
}

fn binaryFoldKind(name: []const u8) ?BinaryFoldKind {
    if (std.mem.eql(u8, name, dialect_mod.AccyDialect.AddOp.operation_name)) return .add;
    if (std.mem.eql(u8, name, dialect_mod.AccyDialect.SubOp.operation_name)) return .sub;
    if (std.mem.eql(u8, name, dialect_mod.AccyDialect.MulOp.operation_name)) return .mul;
    return null;
}

fn unaryFoldKind(name: []const u8) ?UnaryFoldKind {
    if (std.mem.eql(u8, name, dialect_mod.AccyDialect.NegOp.operation_name)) return .neg;
    if (std.mem.eql(u8, name, dialect_mod.AccyDialect.FloorOp.operation_name)) return .floor;
    if (std.mem.eql(u8, name, dialect_mod.AccyDialect.RoundOp.operation_name)) return .round;
    if (std.mem.eql(u8, name, dialect_mod.AccyDialect.TruncOp.operation_name)) return .trunc;
    return null;
}

fn foldBinaryElementwiseConstant(
    ctx: *ir.Context,
    op: *ir.Operation,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    rewriter: *rewrite.PatternRewriter,
    kind: BinaryFoldKind,
) !bool {
    if (op.getNumOperands() != 2 or op.getNumResults() != 1) return false;
    const lhs = op.getOperand(0) orelse return false;
    const rhs = op.getOperand(1) orelse return false;
    const result = op.getResult(0) orelse return false;
    const lhs_const = constantDefiningOp(lhs) orelse return false;
    const rhs_const = constantDefiningOp(rhs) orelse return false;
    const result_info = analysis.get(result) orelse return false;
    const expected_bytes = expectedPayloadBytes(result_info) orelse return false;

    const lhs_payload = (dialect_mod.AccyDialect.ConstantOp{ .op = lhs_const }).getPayload() orelse
        return false;
    const rhs_payload = (dialect_mod.AccyDialect.ConstantOp{ .op = rhs_const }).getPayload() orelse
        return false;
    if (lhs_payload.len != expected_bytes or rhs_payload.len != expected_bytes) return false;

    const folded_payload = (try foldBinaryPayload(
        rewriter.allocator,
        kind,
        result_info.dtype,
        lhs_payload,
        rhs_payload,
        result_info.element_count.?,
    )) orelse return false;
    defer rewriter.allocator.free(folded_payload);

    const folded = try createConstantBefore(ctx, rewriter, op, folded_payload, result.type);
    try rewriter.replaceOpWithValue(op, folded.getResult());
    return true;
}

fn foldUnaryElementwiseConstant(
    ctx: *ir.Context,
    op: *ir.Operation,
    analysis: *const shape_analysis.ShapeLayoutAnalysis,
    rewriter: *rewrite.PatternRewriter,
    kind: UnaryFoldKind,
) !bool {
    if (op.getNumOperands() != 1 or op.getNumResults() != 1) return false;
    const input = op.getOperand(0) orelse return false;
    const result = op.getResult(0) orelse return false;
    const input_const = constantDefiningOp(input) orelse return false;
    const result_info = analysis.get(result) orelse return false;
    const expected_bytes = expectedPayloadBytes(result_info) orelse return false;

    const input_payload = (dialect_mod.AccyDialect.ConstantOp{
        .op = input_const,
    }).getPayload() orelse return false;
    if (input_payload.len != expected_bytes) return false;

    const folded_payload = (try foldUnaryPayload(
        rewriter.allocator,
        kind,
        result_info.dtype,
        input_payload,
        result_info.element_count.?,
    )) orelse return false;
    defer rewriter.allocator.free(folded_payload);

    const folded = try createConstantBefore(ctx, rewriter, op, folded_payload, result.type);
    try rewriter.replaceOpWithValue(op, folded.getResult());
    return true;
}

fn expectedPayloadBytes(info: shape_analysis.TensorInfo) ?usize {
    if (!info.hasStaticLayout()) return null;
    const bytes = std.math.mul(
        u64,
        info.element_count.?,
        @as(u64, info.dtype.sizeOf()),
    ) catch return null;
    if (bytes > std.math.maxInt(usize)) return null;
    return @intCast(bytes);
}

fn foldBinaryPayload(
    allocator: std.mem.Allocator,
    kind: BinaryFoldKind,
    dtype: DType,
    lhs_payload: []const u8,
    rhs_payload: []const u8,
    element_count: u64,
) !?[]u8 {
    if (element_count > std.math.maxInt(usize)) return null;
    const count: usize = @intCast(element_count);
    return switch (dtype) {
        .f32 => try foldBinaryPayloadTyped(f32, allocator, kind, lhs_payload, rhs_payload, count),
        .f64 => try foldBinaryPayloadTyped(f64, allocator, kind, lhs_payload, rhs_payload, count),
        .i32 => try foldBinaryPayloadTyped(i32, allocator, kind, lhs_payload, rhs_payload, count),
        .i64 => try foldBinaryPayloadTyped(i64, allocator, kind, lhs_payload, rhs_payload, count),
        else => null,
    };
}

fn foldUnaryPayload(
    allocator: std.mem.Allocator,
    kind: UnaryFoldKind,
    dtype: DType,
    input_payload: []const u8,
    element_count: u64,
) !?[]u8 {
    if (element_count > std.math.maxInt(usize)) return null;
    const count: usize = @intCast(element_count);
    return switch (dtype) {
        .f32 => try foldUnaryPayloadTyped(f32, allocator, kind, input_payload, count),
        .f64 => try foldUnaryPayloadTyped(f64, allocator, kind, input_payload, count),
        .i32 => try foldUnaryPayloadTyped(i32, allocator, kind, input_payload, count),
        .i64 => try foldUnaryPayloadTyped(i64, allocator, kind, input_payload, count),
        else => null,
    };
}

fn foldBinaryPayloadTyped(
    comptime T: type,
    allocator: std.mem.Allocator,
    kind: BinaryFoldKind,
    lhs_payload: []const u8,
    rhs_payload: []const u8,
    element_count: usize,
) !?[]u8 {
    const byte_count = std.math.mul(usize, element_count, @sizeOf(T)) catch return null;
    const payload = try allocator.alloc(u8, byte_count);
    var keep_payload = false;
    defer if (!keep_payload) allocator.free(payload);
    for (0..element_count) |i| {
        const lhs = readPayloadScalar(T, lhs_payload, i);
        const rhs = readPayloadScalar(T, rhs_payload, i);
        const folded = foldBinaryScalar(T, kind, lhs, rhs) orelse return null;
        writePayloadScalar(T, payload, i, folded);
    }
    keep_payload = true;
    return payload;
}

fn foldUnaryPayloadTyped(
    comptime T: type,
    allocator: std.mem.Allocator,
    kind: UnaryFoldKind,
    input_payload: []const u8,
    element_count: usize,
) !?[]u8 {
    const byte_count = std.math.mul(usize, element_count, @sizeOf(T)) catch return null;
    const payload = try allocator.alloc(u8, byte_count);
    var keep_payload = false;
    defer if (!keep_payload) allocator.free(payload);
    for (0..element_count) |i| {
        const input = readPayloadScalar(T, input_payload, i);
        const folded = foldUnaryScalar(T, kind, input) orelse return null;
        writePayloadScalar(T, payload, i, folded);
    }
    keep_payload = true;
    return payload;
}

fn foldBinaryScalar(comptime T: type, kind: BinaryFoldKind, lhs: T, rhs: T) ?T {
    return switch (@typeInfo(T)) {
        .float => switch (kind) {
            .add => lhs + rhs,
            .sub => lhs - rhs,
            .mul => lhs * rhs,
        },
        .int => checkedBinaryInt(T, kind, lhs, rhs),
        else => null,
    };
}

fn foldUnaryScalar(comptime T: type, kind: UnaryFoldKind, value: T) ?T {
    return switch (@typeInfo(T)) {
        .float => switch (kind) {
            .neg => -value,
            .floor => @floor(value),
            .round => @round(value),
            .trunc => @trunc(value),
        },
        .int => switch (kind) {
            .neg => checkedNegInt(T, value),
            .floor, .round, .trunc => null,
        },
        else => null,
    };
}

fn checkedBinaryInt(comptime T: type, kind: BinaryFoldKind, lhs: T, rhs: T) ?T {
    const folded: i128 = switch (kind) {
        .add => @as(i128, lhs) + @as(i128, rhs),
        .sub => @as(i128, lhs) - @as(i128, rhs),
        .mul => @as(i128, lhs) * @as(i128, rhs),
    };
    if (folded < @as(i128, std.math.minInt(T))) return null;
    if (folded > @as(i128, std.math.maxInt(T))) return null;
    return @intCast(folded);
}

fn checkedNegInt(comptime T: type, value: T) ?T {
    if (value == std.math.minInt(T)) return null;
    return -value;
}

fn readPayloadScalar(comptime T: type, payload: []const u8, index: usize) T {
    const start = index * @sizeOf(T);
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), payload[start..][0..@sizeOf(T)]);
    return value;
}

fn writePayloadScalar(comptime T: type, payload: []u8, index: usize, value: T) void {
    const start = index * @sizeOf(T);
    @memcpy(payload[start..][0..@sizeOf(T)], std.mem.asBytes(&value));
}

fn constantDefiningOp(value: *ir.Value) ?*ir.Operation {
    const def_any = value.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!std.mem.eql(u8, def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
        return null;
    }
    return def_op;
}

fn createConstantBefore(
    ctx: *ir.Context,
    rewriter: *rewrite.PatternRewriter,
    before: *ir.Operation,
    payload: []const u8,
    result_type: ir.Type,
) !dialect_mod.AccyDialect.ConstantOp {
    rewriter.setInsertionPointBefore(before);
    var state = ir.Operation.State.initStatic(
        dialect_mod.AccyDialect.ConstantOp.operation_name,
        before.location,
    );
    state.addTypes(&.{result_type});
    const op = try rewriter.create(state);
    const payload_attr = try ctx.getDialectAttr(
        dialect_mod.AccyDialect.ConstantOp.payload_attr_name,
        payload,
    );
    try op.setAttr("payload", payload_attr);
    return .{ .op = op };
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

fn foldingFixture(shape: []const i64, copies: u32) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(testing.allocator, .standard);
    defer builder.deinit();
    const scalar = try builder.tensor(.f32, &.{1});
    const vector = try builder.tensor(.f32, shape);
    var function = try builder.beginFunction("fold_accounting", &.{}, &.{vector});
    const value = [_]f32{2};
    var result = try function.constant(scalar, std.mem.sliceAsBytes(&value));
    result = try function.broadcastInDim(result, vector, shape, &.{0});
    for (0..copies) |_| result = try function.neg(result);
    try function.return_(&.{result});
    try function.finish();
    return builder.finish();
}

fn expectFoldingPayload(module: *semantic.SemanticModule, span: u32, copies: u32) !void {
    const body = module.choir_module.getRegion(0).?.getEntryBlock().?;
    const function = ir.inspection.functionByNameInBlock(body, "fold_accounting").?;
    const block = function.getRegion(0).?.getEntryBlock().?;
    const ret = findOpNamedInBlock(block, "func.return").?;
    const constant = constantDefiningOp(ret.getOperand(0).?) orelse
        return error.TestExpectedConstant;
    const payload = (dialect_mod.AccyDialect.ConstantOp{ .op = constant }).getPayload().?;
    try testing.expectEqual(@as(usize, span) * @sizeOf(f32), payload.len);
    const expected: f32 = if (copies % 2 == 0) 2 else -2;
    for (0..span) |index| try testing.expectEqual(expected, readPayloadScalar(f32, payload, index));
}

fn checkFoldingAccounting(admitted: bool) !void {
    const allocator = testing.allocator;
    const revision = choir.product.revision;
    const module = try foldingFixture(&.{17}, 3);
    defer module.deinit();
    const root = module.choir_module;
    const before = try choir.bytecode.encodeModule(allocator, root);
    defer allocator.free(before);
    const bounds = try foldingWork(.{ .operation = root });
    var allowance = revision.WorkVector.uniform(1 << 40);
    if (!admitted) allowance.structural_visits = bounds.work.structural_visits - 1;
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = allowance,
        .workspace = 1 << 24,
        .events = 8,
    }, &.{.{ .name = constant_folding_pass_name, .version = 1 }});
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(
        allocator,
        null,
        ledger,
        .{ .context = module.context() },
        1,
    );
    defer cache.deinit();
    var manager = passes.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(constantFoldingPass());
    const result = manager.runWithAnalysisCache(root, module.context(), &cache, .{});
    try testing.expectEqual(if (admitted) passes.PassResult.success else .failure, result);
    if (admitted) {
        try ledger.producersComplete();
        try testing.expect(!ledger.view().missing_work_contract);
        try testing.expectEqual(@as(u64, 1), ledger.view().executed.counters.pass_runs);
        try expectFoldingPayload(module, 17, 3);
    } else {
        try testing.expectEqual(.exhausted, ledger.view().outcome);
        try testing.expectEqual(@as(u64, 0), manager.stats.pass_runs);
        try testing.expectEqual(@as(usize, 0), cache.entries.count());
        const after = try choir.bytecode.encodeModule(allocator, root);
        defer allocator.free(after);
        try testing.expectEqualSlices(u8, before, after);
    }
}

fn checkFoldingStorage(module: *semantic.SemanticModule, span: u32, copies: u32) !void {
    const allocator = testing.allocator;
    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var context = passes.PassContext.init(module.choir_module, module.context(), allocator, &cache);
    defer context.deinit();
    _ = try shape_analysis.getShapeLayoutAnalysis(&context, module.choir_module);
    const bounds = try foldingWork(.{ .operation = module.choir_module });
    const bytes = try allocator.alloc(u8, @intCast(bounds.workspace));
    defer allocator.free(bytes);
    var storage = @import("alloc_fixed").Tracked.init(bytes);
    context.allocator = storage.allocator();
    defer context.allocator = allocator;
    try testing.expectEqual(.success, runConstantFoldingPass(&context));
    try testing.expect(!storage.exhausted);
    try testing.expect(storage.status().high_water_bytes <= bounds.workspace);
    try testing.expect(storage.status().high_water_bytes > 0);
    try expectFoldingPayload(module, span, copies);
}

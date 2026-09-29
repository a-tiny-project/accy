const std = @import("std");
const alloc_arena = @import("alloc_arena");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const kernel_library = @import("../kernel/library/root.zig");
const kernel_selection = @import("../kernel/logical/selection/root.zig");
const call_preparation = @import("call.zig");
const library_preparation = @import("library.zig");

const ir = choir.ir;
const rewrite = ir.rewrite;
const passes = choir.passes;
const work = passes.pass.work;
const dialect_mod = accy_choir.dialect;
const semantics = accy_choir.semantics;

pub const Options = struct {
    kernel_library: library_preparation.KernelLibraryLowering = .disabled,

    pub fn eql(self: Options, other: Options) bool {
        return self.kernel_library == other.kernel_library;
    }
};

pub const activation_lowering_pass_name = "accy-choir-activation-lower";
pub const activation_lowering_pass_description =
    "Lower semantic Accy activation patterns into selected tensor kernels";

const kernel_library_option_choices = [_]passes.PassOptionChoice{
    .{ .name = "disabled" },
    .{ .name = "enabled" },
};

pub const activation_lowering_pass_options = [_]passes.PassOptionSpec{
    .{
        .name = "kernel-library",
        .description = "Use kernel library calls for supported activation patterns",
        .kind = .choice,
        .choices = &kernel_library_option_choices,
        .default_value = "disabled",
    },
};

pub fn activationLoweringPass() passes.Pass {
    return .{
        .name = activation_lowering_pass_name,
        .description = activation_lowering_pass_description,
        .run_fn = runActivationLoweringPass,
        .work_contract = activation_work_contract,
    };
}

pub fn activationLoweringPassWithOptions(options: *const Options) passes.Pass {
    return .{
        .name = activation_lowering_pass_name,
        .description = activation_lowering_pass_description,
        .state = @constCast(options),
        .run_with_state_fn = runActivationLoweringPassWithState,
        .work_contract = activation_work_contract,
    };
}

pub fn activationLoweringPassFromOptions(allocator: std.mem.Allocator, set: passes.PassOptionSet) anyerror!passes.Pass {
    const options = try allocator.create(Options);
    errdefer allocator.destroy(options);
    options.* = .{
        .kernel_library = try kernelLibraryLoweringFromText(set.choiceValue("kernel-library", "disabled")),
    };
    var pass = activationLoweringPassWithOptions(options);
    pass.state_deinit_fn = destroyOptions;
    return pass;
}

const activation_work_contract: work.Contract = .{
    .identity = .{ .name = activation_lowering_pass_name, .version = 1 },
    .estimate = activationWork,
};

const ActivationWork = struct {
    options: Options,
    created: u64 = 0,
    erased: u64 = 0,
    payload: u64 = 0,
    temporary: u64 = 0,
    metadata: u64 = 0,

    fn visit(self: *ActivationWork, op: *ir.Operation) !ir.WalkResult {
        const activation = std.mem.eql(
            u8,
            op.name.name,
            dialect_mod.AccyDialect.ActivationOp.operation_name,
        );
        const maximum = std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.MaxOp.operation_name);
        if (!activation and !(maximum and self.options.kernel_library == .enabled)) return .advance;
        if (op.getNumResults() != 1) return .advance;
        const kind = if (activation) activationKindFromOp(op) orelse return .advance else .relu;
        const shape = try ActivationShape.inspect(op.getResult(0).?.type);
        const decoding = try work.multiply(2, try work.add(try work.multiply(shape.rank, 8), 128));
        self.temporary = try work.add(self.temporary, try work.multiply(4, decoding));
        if (self.options.kernel_library == .enabled and shape.rank == 1) {
            if (kernel_selection.selectActivationCatalog(.{
                .dtype = shape.dtype,
                .kind = kind,
                .extent = shape.elements,
            })) |selected| {
                self.created = try work.add(self.created, 1);
                self.erased = try work.add(self.erased, if (maximum) 2 else 1);
                self.temporary = try work.add(self.temporary, 64);
                self.metadata = try work.add(
                    self.metadata,
                    selected.descriptor.metadata.target.len + 64,
                );
                return .advance;
            }
        }
        if (!activation or !shape.dtype.isFloat()) return .advance;
        const constants: u64 = if (kind == .gelu) 4 else 1;
        const nodes: u64 = switch (kind) {
            .relu => 2,
            .silu => 5,
            .gelu => 13,
        };
        self.created = try work.add(self.created, nodes);
        self.erased = try work.add(self.erased, 1);
        self.payload = try work.add(self.payload, try work.multiply(
            constants,
            try work.multiply(shape.elements, shape.dtype.sizeOf()),
        ));
        self.temporary = try work.add(self.temporary, try work.multiply(constants, decoding));
        return .advance;
    }
};

const ActivationShape = struct {
    dtype: semantics.DType,
    rank: u64 = 0,
    elements: u64 = 1,

    fn inspect(typ: ir.Type) !ActivationShape {
        const name = typ.getDialectTypeName() orelse return error.ExpectedAccyTensorType;
        if (!std.mem.eql(u8, name, dialect_mod.tensor_type_name)) {
            return error.ExpectedAccyTensorType;
        }
        const key = typ.getDialectParamKey() orelse return error.MalformedAccyTensorType;
        const comma = std.mem.indexOfScalar(u8, key, ',') orelse
            return error.MalformedAccyTensorType;
        var shape: ActivationShape = .{
            .dtype = semantics.DType.fromName(key[0..comma]) orelse return error.UnknownAccyDType,
        };
        const dims = key[comma + 1 ..];
        if (dims.len == 0) return shape;
        var iter = std.mem.splitScalar(u8, dims, 'x');
        while (iter.next()) |part| {
            const dim = std.fmt.parseInt(i64, part, 10) catch return error.MalformedAccyTensorType;
            if (dim < 0) return error.MalformedAccyTensorType;
            shape.rank = try work.add(shape.rank, 1);
            shape.elements = try work.multiply(shape.elements, @intCast(dim));
        }
        return shape;
    }
};

fn activationWork(input: work.Input) !work.Bounds {
    const options: *const Options = if (input.state) |state| @ptrCast(@alignCast(state)) else &.{};
    const counts = try work.Census.inspect(input.operation);
    var facts: ActivationWork = .{ .options = options.* };
    _ = try input.operation.walk(.{ .order = .pre_order }, &facts, ActivationWork.visit);
    const queues = try work.add(
        try work.arrayListGrowth(*ir.Operation, facts.created),
        try work.arrayListGrowth(*ir.Operation, facts.erased),
    );
    const bytes = try work.add(queues, try work.add(facts.temporary, facts.payload));
    const units = try work.add(try work.add(counts.atoms, counts.input_bytes), 1);
    const uses = try work.add(try work.add(counts.values, counts.operands), facts.created);
    const traversal = try work.multiply(128, try work.multiply(units, try work.add(uses, 1)));
    const nodes = try work.multiply(facts.created, @sizeOf(ir.Operation) + @sizeOf(ir.Value) +
        2 * @sizeOf(ir.OpOperand) + 8 * @sizeOf(ir.NamedAttribute) + 256);
    return .{
        .work = .{
            .input_bytes = counts.input_bytes,
            .output_bytes = try work.add(nodes, try work.add(facts.metadata, facts.payload)),
            .structural_visits = try work.add(traversal, try work.multiply(16, facts.payload)),
            .allocation_capacity = bytes,
        },
        .workspace = bytes,
    };
}

fn destroyOptions(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const options: *Options = @ptrCast(@alignCast(raw orelse return));
    allocator.destroy(options);
}

fn kernelLibraryLoweringFromText(value: []const u8) !library_preparation.KernelLibraryLowering {
    if (std.mem.eql(u8, value, "disabled")) return .disabled;
    if (std.mem.eql(u8, value, "enabled")) return .enabled;
    return error.InvalidPassOptionValue;
}

fn runActivationLoweringPass(pass_ctx: *passes.PassContext) passes.PassResult {
    return runActivationLoweringWithOptions(pass_ctx, .{});
}

fn runActivationLoweringPassWithState(raw: ?*anyopaque, pass_ctx: *passes.PassContext) passes.PassResult {
    const options: *const Options = @ptrCast(@alignCast(raw orelse return .failure));
    return runActivationLoweringWithOptions(pass_ctx, options.*);
}

fn runActivationLoweringWithOptions(pass_ctx: *passes.PassContext, options: Options) passes.PassResult {
    var rewriter = rewrite.PatternRewriter.init(pass_ctx.allocator, pass_ctx.ir_ctx);
    defer rewriter.deinit();

    var lowered_count: usize = 0;
    lowerOnOp(pass_ctx.op, &rewriter, options, &lowered_count) catch return .failure;
    if (lowered_count == 0) {
        pass_ctx.preserveAllAnalyses();
    } else {
        rewriter.finalize(pass_ctx.op);
        pass_ctx.markModified();
    }
    return .success;
}

fn lowerOnOp(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
    options: Options,
    lowered_count: *usize,
) !void {
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                const next = current_op.next_op;
                if (current_op.regions.items.len > 0) {
                    try lowerOnOp(current_op, rewriter, options, lowered_count);
                }
                if (std.mem.eql(u8, current_op.name.name, dialect_mod.AccyDialect.ActivationOp.operation_name)) {
                    var guard = rewriter.insertionGuard();
                    defer guard.deinit();
                    rewriter.setInsertionPointBefore(current_op);
                    if (try lowerActivationOp(current_op, rewriter, options)) {
                        lowered_count.* += 1;
                    }
                } else if (options.kernel_library == .enabled and std.mem.eql(u8, current_op.name.name, dialect_mod.AccyDialect.MaxOp.operation_name)) {
                    var guard = rewriter.insertionGuard();
                    defer guard.deinit();
                    rewriter.setInsertionPointBefore(current_op);
                    if (try lowerReluMaxOp(current_op, rewriter)) |lowered| {
                        lowered_count.* += 1;
                        if (lowered.zero_op) |erased| try rewriter.eraseOp(erased);
                    }
                }
                current = next;
            }
        }
    }
}

fn lowerActivationOp(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
    options: Options,
) !bool {
    if (op.getNumResults() != 1) return false;
    const result = op.getResult(0) orelse return false;
    const operands = op.getOperandValues();
    if (operands.len != 1) return false;
    const input = operands[0];
    if (!input.type.eql(result.type)) return false;
    const kind = activationKindFromOp(op) orelse return false;

    if (options.kernel_library == .enabled) {
        if (try selectedActivationDescriptor(rewriter.allocator, result.type, kind)) |descriptor| {
            const result_types = [_]ir.Type{result.type};
            const call = try call_preparation.insertCatalogCall(rewriter, .{
                .descriptor = descriptor,
                .operands = &.{input},
                .result_types = &result_types,
            });
            try rewriter.replaceOpWithValue(op, call.getFirstResult());
            return true;
        }
    }

    const replacement = try expandActivationToPrimitives(rewriter, result.type, input, kind) orelse return false;
    try rewriter.replaceOpWithValue(op, replacement);
    return true;
}

const LoweredRelu = struct {
    zero_op: ?*ir.Operation,
};

fn lowerReluMaxOp(op: *ir.Operation, rewriter: *rewrite.PatternRewriter) !?LoweredRelu {
    if (!std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.MaxOp.operation_name)) return null;
    if (op.getNumResults() != 1) return null;
    const result = op.getResult(0) orelse return null;
    const operands = op.getOperandValues();
    if (operands.len != 2) return null;

    const match = try matchReluOperands(rewriter.allocator, op, result.type, operands[0], operands[1]) orelse return null;

    const result_types = [_]ir.Type{result.type};
    const call = try call_preparation.insertCatalogCall(rewriter, .{
        .descriptor = match.descriptor,
        .operands = &.{match.input},
        .result_types = &result_types,
    });
    try rewriter.replaceOpWithValue(op, call.getFirstResult());
    return .{ .zero_op = if (match.erase_zero) match.zero_op else null };
}

const ReluMatch = struct {
    input: *ir.Value,
    zero_op: *ir.Operation,
    erase_zero: bool,
    descriptor: kernel_library.CatalogDescriptor,
};

fn matchReluOperands(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    result_type: ir.Type,
    lhs: *ir.Value,
    rhs: *ir.Value,
) !?ReluMatch {
    if (try matchReluOperandOrder(allocator, op, result_type, lhs, rhs)) |match| return match;
    return try matchReluOperandOrder(allocator, op, result_type, rhs, lhs);
}

fn matchReluOperandOrder(
    allocator: std.mem.Allocator,
    op: *ir.Operation,
    result_type: ir.Type,
    input: *ir.Value,
    zero: *ir.Value,
) !?ReluMatch {
    const zero_op = constantDefiningOp(zero) orelse return null;
    if (constantDefiningOp(input) != null) return null;
    if (!input.type.eql(result_type) or !zero.type.eql(result_type)) return null;

    var arena_state = alloc_arena.Arena.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tensor_type = try dialect_mod.decodeTensorType(arena, result_type);
    if (tensor_type.dtype != .f32 or tensor_type.dims.len != 1) return null;
    if (tensor_type.dims[0] <= 0) return null;

    const payload = (dialect_mod.AccyDialect.ConstantOp{ .op = zero_op }).getPayload() orelse return null;
    if (!payloadIsZeroF32(payload, @intCast(tensor_type.dims[0]))) return null;

    const descriptor = try selectedActivationDescriptor(allocator, result_type, .relu) orelse return null;

    return .{
        .input = input,
        .zero_op = zero_op,
        .erase_zero = hasOnlyUseBy(zero, op),
        .descriptor = descriptor,
    };
}

fn selectedActivationDescriptor(
    allocator: std.mem.Allocator,
    result_type: ir.Type,
    kind: semantics.ActivationKind,
) !?kernel_library.CatalogDescriptor {
    var arena_state = alloc_arena.Arena.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tensor_type = try dialect_mod.decodeTensorType(arena, result_type);
    if (tensor_type.dtype != .f32 or tensor_type.dims.len != 1) return null;
    if (tensor_type.dims[0] <= 0) return null;
    const extent = std.math.cast(u64, tensor_type.dims[0]) orelse return null;
    const selected = kernel_selection.selectActivationCatalog(.{
        .dtype = .f32,
        .kind = kind,
        .extent = extent,
    }) orelse return null;
    return selected.descriptor;
}

fn activationKindFromOp(op: *ir.Operation) ?semantics.ActivationKind {
    const attr = op.getAttr("activation_kind") orelse return null;
    if (!std.mem.eql(u8, attr.abstract.name, dialect_mod.AccyDialect.ActivationOp.activation_kind_attr_name)) return null;
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
    return semantics.ActivationKind.fromName(dialect_attr.payload);
}

fn expandActivationToPrimitives(
    rewriter: *rewrite.PatternRewriter,
    result_type: ir.Type,
    input: *ir.Value,
    kind: semantics.ActivationKind,
) !?*ir.Value {
    return switch (kind) {
        .relu => try expandRelu(rewriter, result_type, input),
        .silu => try expandSilu(rewriter, result_type, input),
        .gelu => try expandGelu(rewriter, result_type, input),
    };
}

fn expandRelu(
    rewriter: *rewrite.PatternRewriter,
    result_type: ir.Type,
    input: *ir.Value,
) !?*ir.Value {
    const zero = try splatFloatConstant(rewriter, result_type, 0.0) orelse return null;
    const max = try dialect_mod.AccyDialect.MaxOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), input, zero);
    _ = try rewriter.insert(max.op);
    return max.getResult();
}

fn expandSilu(
    rewriter: *rewrite.PatternRewriter,
    result_type: ir.Type,
    input: *ir.Value,
) !?*ir.Value {
    const one = try splatFloatConstant(rewriter, result_type, 1.0) orelse return null;
    const neg = try dialect_mod.AccyDialect.NegOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), input);
    _ = try rewriter.insert(neg.op);
    const exponent = try dialect_mod.AccyDialect.ExpOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), neg.getResult());
    _ = try rewriter.insert(exponent.op);
    const denominator = try dialect_mod.AccyDialect.AddOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), one, exponent.getResult());
    _ = try rewriter.insert(denominator.op);
    const out = try dialect_mod.AccyDialect.DivOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), input, denominator.getResult());
    _ = try rewriter.insert(out.op);
    return out.getResult();
}

fn expandGelu(
    rewriter: *rewrite.PatternRewriter,
    result_type: ir.Type,
    input: *ir.Value,
) !?*ir.Value {
    const c044715 = try splatFloatConstant(rewriter, result_type, 0.044715) orelse return null;
    const c079788 = try splatFloatConstant(rewriter, result_type, 0.7978845608028654) orelse return null;
    const one = try splatFloatConstant(rewriter, result_type, 1.0) orelse return null;
    const half = try splatFloatConstant(rewriter, result_type, 0.5) orelse return null;

    const x2 = try dialect_mod.AccyDialect.MulOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), input, input);
    _ = try rewriter.insert(x2.op);
    const x3 = try dialect_mod.AccyDialect.MulOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), x2.getResult(), input);
    _ = try rewriter.insert(x3.op);
    const scaled_cubic = try dialect_mod.AccyDialect.MulOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), c044715, x3.getResult());
    _ = try rewriter.insert(scaled_cubic.op);
    const inner_sum = try dialect_mod.AccyDialect.AddOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), input, scaled_cubic.getResult());
    _ = try rewriter.insert(inner_sum.op);
    const scaled = try dialect_mod.AccyDialect.MulOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), c079788, inner_sum.getResult());
    _ = try rewriter.insert(scaled.op);
    const activated = try dialect_mod.AccyDialect.TanhOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), scaled.getResult());
    _ = try rewriter.insert(activated.op);
    const bracket = try dialect_mod.AccyDialect.AddOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), one, activated.getResult());
    _ = try rewriter.insert(bracket.op);
    const half_x = try dialect_mod.AccyDialect.MulOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), half, input);
    _ = try rewriter.insert(half_x.op);
    const out = try dialect_mod.AccyDialect.MulOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), half_x.getResult(), bracket.getResult());
    _ = try rewriter.insert(out.op);
    return out.getResult();
}

fn splatFloatConstant(
    rewriter: *rewrite.PatternRewriter,
    result_type: ir.Type,
    value: f64,
) !?*ir.Value {
    var arena_state = alloc_arena.Arena.init(rewriter.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tensor_type = try dialect_mod.decodeTensorType(arena, result_type);
    if (!tensor_type.dtype.isFloat()) return null;
    const count = elementCount(tensor_type) orelse return null;
    const payload_len = std.math.mul(usize, count, tensor_type.dtype.sizeOf()) catch return null;
    const payload = try rewriter.allocator.alloc(u8, payload_len);
    defer rewriter.allocator.free(payload);
    fillFloatPayload(payload, tensor_type.dtype, value);
    const constant = try dialect_mod.AccyDialect.ConstantOp.create(rewriter.ir_ctx, ir.Location.getUnknown(), payload, result_type);
    _ = try rewriter.insert(constant.op);
    return constant.getResult();
}

fn elementCount(tensor_type: semantics.Type) ?usize {
    var count: usize = 1;
    for (tensor_type.dims) |dim| {
        const dim_usize = std.math.cast(usize, dim) orelse return null;
        count = std.math.mul(usize, count, dim_usize) catch return null;
    }
    return count;
}

fn fillFloatPayload(payload: []u8, dtype: semantics.DType, value: f64) void {
    const width = dtype.sizeOf();
    var offset: usize = 0;
    while (offset < payload.len) : (offset += width) {
        switch (dtype) {
            .f16 => {
                var converted: f16 = @floatCast(value);
                @memcpy(payload[offset..][0..@sizeOf(f16)], std.mem.asBytes(&converted));
            },
            .bf16 => {
                const Bf16 = @as(semantics.DType, .bf16).ZigType();
                var converted = Bf16.fromF32(@floatCast(value));
                @memcpy(payload[offset..][0..@sizeOf(Bf16)], std.mem.asBytes(&converted));
            },
            .f32 => {
                var converted: f32 = @floatCast(value);
                @memcpy(payload[offset..][0..@sizeOf(f32)], std.mem.asBytes(&converted));
            },
            .f64 => {
                var converted = value;
                @memcpy(payload[offset..][0..@sizeOf(f64)], std.mem.asBytes(&converted));
            },
            else => unreachable,
        }
    }
}

fn constantDefiningOp(value: *ir.Value) ?*ir.Operation {
    const def_any = value.getDefiningOp() orelse return null;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!std.mem.eql(u8, def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) return null;
    return def_op;
}

fn hasOnlyUseBy(value: *ir.Value, op: *ir.Operation) bool {
    if (!value.hasOneUse()) return false;
    const first = value.first_use orelse return false;
    const owner: *ir.Operation = @ptrCast(@alignCast(first.owner));
    return owner == op;
}

fn payloadIsZeroF32(payload: []const u8, extent: usize) bool {
    if (payload.len != extent * @sizeOf(f32)) return false;
    for (0..extent) |index| {
        var value: f32 = undefined;
        const start = index * @sizeOf(f32);
        @memcpy(std.mem.asBytes(&value), payload[start..][0..@sizeOf(f32)]);
        if (value != 0.0) return false;
    }
    return true;
}

const testing = std.testing;
const semantic = accy_choir.semantic;

const ActivationCase = struct {
    dims: []const i64 = &.{8},
    dtype: semantics.DType = .f32,
    kind: semantics.ActivationKind = .gelu,
    copies: u32 = 1,
    library: library_preparation.KernelLibraryLowering = .disabled,
    calls: bool = false,
    maximum: bool = false,

    fn module(self: ActivationCase) !*semantic.SemanticModule {
        var limits = semantic.Builder.ContextLimits.standard;
        var elements: usize = 1;
        for (self.dims) |dim| elements = try std.math.mul(usize, elements, @intCast(dim));
        const payload = try std.math.mul(usize, elements, self.dtype.sizeOf());
        limits.attributes.payload_bytes += try std.math.mul(usize, payload, 4 * self.copies);
        var builder = try semantic.Builder.init(testing.allocator, limits);
        defer builder.deinit();
        const tensor = try builder.tensor(self.dtype, self.dims);
        var function = try builder.beginFunction("activation_accounting", &.{tensor}, &.{tensor});
        var value = function.parameter(0);
        for (0..self.copies) |index| {
            if (self.maximum) {
                const bytes = try testing.allocator.alloc(u8, payload);
                defer testing.allocator.free(bytes);
                @memset(bytes, 0);
                const zero = try function.constant(tensor, bytes);
                value = if (index % 2 == 0)
                    try function.max(value, zero)
                else
                    try function.max(zero, value);
            } else {
                value = try function.activation(value, self.kind);
            }
        }
        try function.return_(&.{value});
        try function.finish();
        return builder.finish();
    }

    fn check(self: ActivationCase, module_: *semantic.SemanticModule) !void {
        try module_.verify();
        const root = module_.choir_module;
        try testing.expectEqual(
            @as(usize, 0),
            ir.inspection.countOperationsNamed(root, "accy.activation"),
        );
        try testing.expectEqual(
            @as(usize, if (self.calls) self.copies else 0),
            ir.inspection.countOperationsNamed(root, "accy.kernel_call"),
        );
        var constants: ConstantWitness = .{ .case = self };
        _ = try root.walk(.{ .order = .pre_order }, &constants, ConstantWitness.visit);
        const per_activation: u64 = if (self.kind == .gelu) 4 else 1;
        const count: u64 = if (self.calls) 0 else self.copies * per_activation;
        try testing.expectEqual(count, constants.count);
    }
};

const ConstantWitness = struct {
    case: ActivationCase,
    count: u64 = 0,

    fn visit(self: *ConstantWitness, op: *ir.Operation) !ir.WalkResult {
        if (!std.mem.eql(u8, op.name.name, "accy.constant")) return .advance;
        const payload = (dialect_mod.AccyDialect.ConstantOp{ .op = op }).getPayload().?;
        var elements: usize = 1;
        for (self.case.dims) |dim| elements *= @intCast(dim);
        try testing.expectEqual(elements * self.case.dtype.sizeOf(), payload.len);
        const value: f64 = switch (self.case.kind) {
            .relu => 0,
            .silu => 1,
            .gelu => ([_]f64{ 0.044715, 0.7978845608028654, 1, 0.5 })[self.count % 4],
        };
        var bytes: [@sizeOf(f64)]u8 = undefined;
        const scalar = bytes[0..self.case.dtype.sizeOf()];
        fillFloatPayload(scalar, self.case.dtype, value);
        for (0..elements) |index| {
            try testing.expectEqualSlices(
                u8,
                scalar,
                payload[index * scalar.len ..][0..scalar.len],
            );
        }
        self.count += 1;
        return .advance;
    }
};

fn checkActivationAccounting(admitted: bool, constructor: u32) !void {
    const allocator = testing.allocator;
    const revision = choir.product.revision;
    const fixture: ActivationCase = .{
        .library = if (constructor == 0) .disabled else .enabled,
        .calls = constructor != 0,
    };
    const module = try fixture.module();
    defer module.deinit();
    const root = module.choir_module;
    const before = try choir.bytecode.encodeModule(allocator, root);
    defer allocator.free(before);
    const options: Options = .{ .kernel_library = fixture.library };
    const bounds = try activationWork(.{ .operation = root, .state = &options });
    var allowance = revision.WorkVector.uniform(1 << 40);
    if (!admitted) allowance.structural_visits = bounds.work.structural_visits - 1;
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = allowance,
        .workspace = 1 << 24,
        .events = 4,
    }, &.{.{ .name = activation_lowering_pass_name, .version = 1 }});
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(
        allocator,
        null,
        ledger,
        .{ .context = module.context() },
        0,
    );
    defer cache.deinit();
    var manager = passes.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(switch (constructor) {
        0 => activationLoweringPass(),
        1 => activationLoweringPassWithOptions(&options),
        2 => try activationLoweringPassFromOptions(allocator, .{
            .assignments = &.{.{ .name = "kernel-library", .value = "enabled" }},
        }),
        else => unreachable,
    });
    const result = manager.runWithAnalysisCache(root, module.context(), &cache, .{});
    try testing.expectEqual(if (admitted) passes.PassResult.success else .failure, result);
    if (admitted) {
        try ledger.producersComplete();
        try testing.expect(!ledger.view().missing_work_contract);
        try testing.expectEqual(@as(u64, 1), ledger.view().executed.counters.pass_runs);
        try fixture.check(module);
    } else {
        try testing.expectEqual(.exhausted, ledger.view().outcome);
        try testing.expectEqual(@as(u64, 0), manager.stats.pass_runs);
        const after = try choir.bytecode.encodeModule(allocator, root);
        defer allocator.free(after);
        try testing.expectEqualSlices(u8, before, after);
    }
}

test "activation lowering accounts each constructor and refuses before mutation" {
    for (0..3) |constructor| {
        try checkActivationAccounting(false, @intCast(constructor));
        try checkActivationAccounting(true, @intCast(constructor));
    }
}

fn checkActivationStorage(fixture: ActivationCase) !void {
    const allocator = testing.allocator;
    const module = try fixture.module();
    defer module.deinit();
    const options: Options = .{ .kernel_library = fixture.library };
    const bounds = try activationWork(.{ .operation = module.choir_module, .state = &options });
    const bytes = try allocator.alloc(u8, @intCast(bounds.workspace));
    defer allocator.free(bytes);
    var storage = @import("alloc_fixed").Tracked.init(bytes);
    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var context = passes.PassContext.init(module.choir_module, module.context(), allocator, &cache);
    defer context.deinit();
    context.allocator = storage.allocator();
    defer context.allocator = allocator;
    const result = runActivationLoweringWithOptions(&context, options);
    try testing.expect(!storage.exhausted);
    try testing.expectEqual(null, module.context().exhaustedSegment());
    try testing.expectEqual(.success, result);
    try testing.expect(storage.status().high_water_bytes <= bounds.workspace);
    try testing.expect(storage.status().high_water_bytes > 0);
    try fixture.check(module);
}

test "activation lowering scratch covers full tensor payloads and repeated expansion" {
    const shapes = [_][]const i64{
        &.{}, &.{0}, &.{20000}, &.{ 2, 3 }, &.{ 1, 1, 1, 1, 1, 1, 1, 1 },
    };
    for (shapes) |shape| {
        for ([_]semantics.ActivationKind{ .relu, .silu, .gelu }) |kind| {
            for ([_]u32{ 1, 17 }) |copies| {
                try checkActivationStorage(.{ .dims = shape, .kind = kind, .copies = copies });
            }
        }
    }
    for ([_]semantics.DType{ .f16, .bf16, .f64 }) |dtype| {
        try checkActivationStorage(.{ .dims = &.{20000}, .dtype = dtype });
    }
}

test "activation lowering scratch covers selected catalog and primitive fallback" {
    for ([_]semantics.ActivationKind{ .relu, .silu, .gelu }) |kind| {
        try checkActivationStorage(.{
            .kind = kind,
            .copies = 17,
            .library = .enabled,
            .calls = true,
        });
        try checkActivationStorage(.{ .dims = &.{20000}, .kind = kind, .library = .enabled });
    }
    try checkActivationStorage(.{
        .kind = .relu,
        .copies = 17,
        .library = .enabled,
        .calls = true,
        .maximum = true,
    });
    try checkActivationStorage(.{
        .dims = &.{16},
        .kind = .relu,
        .library = .enabled,
        .maximum = true,
    });
}

test "activation lowering pass selects kernel library relu" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    const zeros = @as([8]f32, @splat(0.0));
    var fb = try builder.beginFunction("activation_kernel_library_relu_lowering_pass", &.{f32_8}, &.{f32_8});
    const zero = try fb.constant(f32_8, std.mem.sliceAsBytes(zeros[0..]));
    const out = try fb.max(fb.parameter(0), zero);
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(activationLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.MaxOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ConstantOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "activation lowering pass selects kernel library gelu activation op" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("activation_kernel_library_gelu_op_lowering_pass", &.{f32_8}, &.{f32_8});
    const out = try fb.activation(fb.parameter(0), .gelu);
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(activationLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ActivationOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "activation lowering pass expands silu activation op by default" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("activation_default_silu_op_lowering_pass", &.{f32_8}, &.{f32_8});
    const out = try fb.activation(fb.parameter(0), .silu);
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(activationLoweringPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ActivationOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.NegOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ExpOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DivOp.operation_name));
}

test "activation lowering pass keeps relu generic by default" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    const zeros = @as([8]f32, @splat(0.0));
    var fb = try builder.beginFunction("activation_registered_relu_generic_lowering_pass", &.{f32_8}, &.{f32_8});
    const zero = try fb.constant(f32_8, std.mem.sliceAsBytes(zeros[0..]));
    const out = try fb.max(zero, fb.parameter(0));
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(activationLoweringPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.MaxOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ConstantOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "activation lowering pass falls back when activation catalog shape is unavailable" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_16 = try builder.tensor(.f32, &.{16});
    var fb = try builder.beginFunction("activation_unavailable_gelu_op_lowering_pass", &.{f32_16}, &.{f32_16});
    const out = try fb.activation(fb.parameter(0), .gelu);
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(activationLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ActivationOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.TanhOp.operation_name));
}

test "activation lowering pass rejects unavailable relu catalog shape" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_16 = try builder.tensor(.f32, &.{16});
    const zeros = @as([16]f32, @splat(0.0));
    var fb = try builder.beginFunction("activation_unavailable_relu_lowering_pass", &.{f32_16}, &.{f32_16});
    const zero = try fb.constant(f32_16, std.mem.sliceAsBytes(zeros[0..]));
    const out = try fb.max(fb.parameter(0), zero);
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(activationLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.MaxOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ConstantOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

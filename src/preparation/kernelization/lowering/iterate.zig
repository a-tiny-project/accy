const std = @import("std");
const gpu_abi = @import("gpu_abi");
const alloc_fixed = @import("alloc_fixed");
const generated_abi = @import("abi.zig");
const generated_builder = @import("builder.zig");
const common = @import("common.zig");
const random = @import("../../../kernel/library/random/root.zig");
const generated_elementwise = @import("elementwise.zig");
const generated_guard = @import("guard.zig");
const generated_name = @import("name.zig");
const generated_schedule = @import("schedule.zig");

const ir = common.ir;
const dialect_mod = common.dialect_mod;
const kernel_root = common.kernel_root;
const bufferization = common.bufferization;
const kernelization_model = @import("../model/root.zig");
const schedule_planning = common.schedule_planning;
const bufferSlotById = common.bufferSlotById;
const externalInputIndex = common.externalInputIndex;
const mapKernelBuildError = common.mapKernelBuildError;
const mapGeneratedKernelError = common.mapGeneratedKernelError;
const isName = common.isName;

const LoweredKernel = kernelization_model.LoweredKernel;

const max_captures = 8;
const max_body_ops = 160;
const max_carries = 8;

const IterateDescription = struct {
    op: *ir.Operation,
    block: *ir.Block,
    yield_op: *ir.Operation,
    carries: [max_carries]*ir.Value,
    carry_elements: [max_carries]u64,
    carry_count: usize,
    element_count: u64,
    max_iters: i64,
    captures: [max_captures]*ir.Value,
    capture_elements: [max_captures]u64,
    capture_count: usize,
};

pub fn lower(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: kernelization_model.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) common.LoweringError!LoweredKernel {
    const desc = try iterateDescriptionForWork(work);

    const input_dtypes = allocator.alloc(gpu_abi.DType, outline.inputCount()) catch return error.OutOfMemory;
    defer allocator.free(input_dtypes);
    for (outline.input_slot_ids, 0..) |slot_id, index| {
        const slot = bufferSlotById(buffer_plan, slot_id) orelse return error.InvalidArtifact;
        input_dtypes[index] = slot.dtype;
    }

    const output_slot = bufferSlotById(buffer_plan, outline.output_slot_id) orelse return error.InvalidArtifact;
    var abi = try generated_abi.flatTyped(allocator, output_slot.dtype, input_dtypes);
    defer abi.deinit(allocator);

    const entry_name = try generated_name.iterate(allocator, work.ops[0].getNumOperands(), desc.max_iters, work.id);
    errdefer allocator.free(entry_name);
    return generated_builder.withoutLaunch(allocator, ir_ctx, work.id, entry_name, abi.params(), generated_schedule.flat(), .{
        .abi = abi,
        .allocator = allocator,
        .desc = desc,
        .outline = outline,
        .buffer_plan = buffer_plan,
    }, emitIterateBody);
}

fn iterateDescriptionForWork(
    work: schedule_planning.ScheduleWorkItem,
) common.LoweringError!IterateDescription {
    if (work.kind != .iterate) return error.UnsupportedOperation;
    if (work.ops.len != 1) return error.UnsupportedOperation;
    const op = work.ops[0];
    if (!isName(op.name.name, dialect_mod.AccyDialect.IterateOp.operation_name)) return error.UnsupportedOperation;
    if (op.getNumOperands() < 1 or op.getNumOperands() > max_carries) return error.UnsupportedOperation;
    if (op.getNumResults() != op.getNumOperands()) return error.UnsupportedOperation;

    const iterate_op = dialect_mod.AccyDialect.IterateOp{ .op = op };
    const max_iters = iterate_op.getMaxIters() orelse return error.InvalidArtifact;
    if (max_iters < 1) return error.InvalidArtifact;
    const block = iterate_op.bodyBlock() orelse return error.InvalidArtifact;
    const terminator_any = block.operations.tail orelse return error.InvalidArtifact;
    const yield_op: *ir.Operation = @ptrCast(@alignCast(terminator_any));
    if (!isName(yield_op.name.name, dialect_mod.AccyDialect.IterateYieldOp.operation_name)) return error.InvalidArtifact;

    var carries: [max_carries]*ir.Value = undefined;
    const carry_count = op.getNumOperands();
    var element_count: u64 = 1;
    for (0..carry_count) |carry_index| {
        const carry = op.getOperand(carry_index) orelse return error.InvalidArtifact;
        carries[carry_index] = carry;
        var dims_arena_buffer: [256]u8 = undefined;
        var dims_arena = alloc_fixed.FixedBuffer.init(dims_arena_buffer[0..]);
        const carry_type = dialect_mod.decodeTensorType(dims_arena.allocator(), carry.type) catch return error.InvalidArtifact;
        if (!iterableBufferDType(carry_type.dtype)) return error.UnsupportedOperation;
        var carry_elements: u64 = 1;
        for (carry_type.dims) |dim| {
            if (dim < 1) return error.UnsupportedOperation;
            carry_elements *= @intCast(dim);
        }
        if (carry_index == 0 or element_count == 1) {
            element_count = carry_elements;
        } else if (carry_elements != 1 and carry_elements != element_count) {
            return error.UnsupportedOperation;
        }
    }

    var desc = IterateDescription{
        .op = op,
        .block = block,
        .yield_op = yield_op,
        .carries = carries,
        .carry_elements = undefined,
        .carry_count = carry_count,
        .element_count = element_count,
        .max_iters = max_iters,
        .captures = undefined,
        .capture_elements = undefined,
        .capture_count = 0,
    };
    for (0..carry_count) |carry_index| {
        desc.carry_elements[carry_index] = try valueElementCount(desc.carries[carry_index]);
    }

    var op_count: usize = 0;
    var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
    while (current) |body_op| : (current = body_op.next_op) {
        op_count += 1;
        if (op_count > max_body_ops) return error.UnsupportedOperation;
        if (body_op == desc.yield_op) continue;
        if (!isName(body_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name) and
            !interiorBroadcastOfConstant(body_op, block) and
            !interiorReshapeSameElementCount(body_op) and
            supportedKernelCall(body_op, desc.element_count) == null and
            generated_elementwise.kernelForOperation(body_op) == null)
        {
            return error.UnsupportedOperation;
        }
        if (isName(body_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) continue;
        if (interiorBroadcastOfConstant(body_op, block)) continue;
        if (interiorReshapeSameElementCount(body_op)) continue;
        if (supportedKernelCall(body_op, desc.element_count) != null) continue;
        for (body_op.getOperandValues()) |operand| {
            try noteCapture(&desc, operand);
        }
    }
    for (desc.yield_op.getOperandValues()) |operand| {
        try noteCapture(&desc, operand);
    }

    return desc;
}

fn iterableDataDType(dtype: gpu_abi.DType) bool {
    return dtype == .f32 or dtype == .f16 or dtype == .bf16 or dtype == .f64 or dtype == .i8 or dtype == .i16 or dtype == .i32 or dtype == .u8 or dtype == .u16 or dtype == .u32 or dtype == .i64 or dtype == .u64;
}

fn iterableBufferDType(dtype: gpu_abi.DType) bool {
    return iterableDataDType(dtype) or dtype == .i1;
}

fn noteCapture(desc: *IterateDescription, operand: *ir.Value) common.LoweringError!void {
    if (operand.getDefiningOp()) |def_any| {
        const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
        const def_block = def_op.getBlock() orelse return error.InvalidArtifact;
        if (def_block == desc.block) return;
    } else {
        const owner_any = operand.getOwnerBlock() orelse return error.InvalidArtifact;
        const owner_block: *ir.Block = @ptrCast(@alignCast(owner_any));
        if (owner_block == desc.block) return;
    }
    for (desc.captures[0..desc.capture_count]) |existing| {
        if (existing == operand) return;
    }
    if (desc.capture_count >= max_captures) return error.UnsupportedOperation;

    const capture_elements = try valueElementCount(operand);
    if (capture_elements != 1 and capture_elements != desc.element_count) return error.UnsupportedOperation;

    desc.captures[desc.capture_count] = operand;
    desc.capture_elements[desc.capture_count] = capture_elements;
    desc.capture_count += 1;
}

fn valueElementCount(value: *ir.Value) common.LoweringError!u64 {
    var dims_arena_buffer: [256]u8 = undefined;
    var dims_arena = alloc_fixed.FixedBuffer.init(dims_arena_buffer[0..]);
    const tensor_type = dialect_mod.decodeTensorType(dims_arena.allocator(), value.type) catch return error.InvalidArtifact;
    var elements: u64 = 1;
    for (tensor_type.dims) |dim| {
        if (dim < 1) return error.UnsupportedOperation;
        elements *= @intCast(dim);
    }
    return elements;
}

fn interiorBroadcastOfConstant(op: *ir.Operation, block: *ir.Block) bool {
    if (!isName(op.name.name, dialect_mod.AccyDialect.BroadcastOp.operation_name) and
        !isName(op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name))
    {
        return false;
    }
    const operands = op.getOperandValues();
    if (operands.len != 1) return false;
    const source_any = operands[0].getDefiningOp() orelse return false;
    const source: *ir.Operation = @ptrCast(@alignCast(source_any));
    if (!isName(source.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) return false;
    const source_block = source.getBlock() orelse return false;
    return source_block == block;
}

fn interiorReshapeSameElementCount(op: *ir.Operation) bool {
    if (!isName(op.name.name, dialect_mod.AccyDialect.ReshapeOp.operation_name)) return false;
    const operands = op.getOperandValues();
    if (operands.len != 1) return false;
    const result = op.getResult(0) orelse return false;
    const source_elements = valueElementCount(operands[0]) catch return false;
    const result_elements = valueElementCount(result) catch return false;
    return source_elements == result_elements;
}

const PhiloxKeyCounterUniformTarget = struct {
    rounds: u32,
    dtype: gpu_abi.DType,
};

fn supportedKernelCall(op: *ir.Operation, domain: u64) ?PhiloxKeyCounterUniformTarget {
    if (!isName(op.name.name, dialect_mod.AccyDialect.KernelCallOp.operation_name)) return null;
    const version_attr = op.getAttrAs(ir.Attribute.IntegerAttr, "version") orelse return null;
    if (version_attr.getValue() != random.philox_key_counter_uniform_family_version) return null;
    const target_attr = op.getAttr("target") orelse return null;
    if (!std.mem.eql(u8, target_attr.abstract.name, dialect_mod.AccyDialect.KernelCallOp.target_attr_name)) return null;
    const target = target_attr.cast(ir.Attribute.DialectAttr) orelse return null;
    const spec = parsePhiloxKeyCounterUniformTarget(target.payload) orelse return null;
    const operands = op.getOperandValues();
    if (operands.len != 2) return null;
    if (!valueHasDTypeAndElements(operands[0], .key, 1)) return null;
    if (!valueHasDTypeAndElements(operands[1], .i32, 1)) return null;
    const result = op.getResult(0) orelse return null;
    if (!valueHasDTypeAndElements(result, spec.dtype, domain)) return null;
    return spec;
}

fn parsePhiloxKeyCounterUniformTarget(target: []const u8) ?PhiloxKeyCounterUniformTarget {
    const prefix = "accy.kernel.random.philox_key_counter_uniform_family_";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];
    const rounds_end = std.mem.indexOf(u8, rest, "r_") orelse return null;
    const rounds = std.fmt.parseInt(u32, rest[0..rounds_end], 10) catch return null;
    const after_rounds = rest[rounds_end + 2 ..];
    const dtype_start = std.mem.lastIndexOfScalar(u8, after_rounds, '_') orelse return null;
    const dtype = gpu_abi.DType.fromName(after_rounds[dtype_start + 1 ..]) orelse return null;
    if (!random.randomDTypeSupported(dtype)) return null;
    return .{ .rounds = rounds, .dtype = dtype };
}

fn valueHasDTypeAndElements(value: *ir.Value, dtype: gpu_abi.DType, elements: u64) bool {
    var arena_buffer: [256]u8 = undefined;
    var arena = alloc_fixed.FixedBuffer.init(arena_buffer[0..]);
    const tensor_type = dialect_mod.decodeTensorType(arena.allocator(), value.type) catch return false;
    if (tensor_type.dtype != dtype) return false;
    return (valueElementCount(value) catch return false) == elements;
}

fn emitIterateBody(logical: anytype, ctx: anytype) !void {
    const desc: IterateDescription = ctx.desc;
    const domain = try logical.index1D("element", desc.element_count);
    try generated_guard.countIndexDo(logical, domain, ctx.abi.count(logical), .{
        .abi = ctx.abi,
        .allocator = ctx.allocator,
        .desc = desc,
        .outline = ctx.outline,
        .buffer_plan = ctx.buffer_plan,
    }, struct {
        fn run(inner: anytype, domain_index: kernel_root.Index1D, guard_ctx: anytype) !void {
            const desc_inner: IterateDescription = guard_ctx.desc;
            const index = domain_index.index;
            const zero_index = try inner.constantIndex(0);

            var capture_values: [max_captures]kernel_root.Value = undefined;
            var initials: [max_carries]kernel_root.Value = undefined;
            var init_args: [max_carries + 1]kernel_root.Value = undefined;
            var init_types: [max_carries + 1]kernel_root.Type = undefined;
            {
                var memo: ?generated_elementwise.ValueMemo = generated_elementwise.ValueMemo.init(guard_ctx.allocator);
                defer if (memo) |*existing| existing.deinit();
                for (desc_inner.captures[0..desc_inner.capture_count], 0..) |capture, capture_index| {
                    const capture_index_value = if (desc_inner.capture_elements[capture_index] == 1) zero_index else index;
                    capture_values[capture_index] = try generated_elementwise.evaluateValueAtIndex(
                        inner,
                        &memo,
                        capture_index_value,
                        capture,
                        guard_ctx.outline,
                        guard_ctx.buffer_plan,
                        guard_ctx.abi,
                        generated_elementwise.max_recompute_depth,
                    );
                }
                for (0..desc_inner.carry_count) |carry_index| {
                    const carry_index_value = if (desc_inner.carry_elements[carry_index] == 1) zero_index else index;
                    initials[carry_index] = try generated_elementwise.evaluateValueAtIndex(
                        inner,
                        &memo,
                        carry_index_value,
                        desc_inner.carries[carry_index],
                        guard_ctx.outline,
                        guard_ctx.buffer_plan,
                        guard_ctx.abi,
                        generated_elementwise.max_recompute_depth,
                    );
                    init_args[carry_index] = initials[carry_index];
                    init_types[carry_index] = initials[carry_index].valueType();
                }
            }
            const zero_iter = try inner.constantInt(.i32, 0);
            const max_iters_value = try inner.constantInt(.i32, @intCast(desc_inner.max_iters));
            const one = try inner.constantInt(.i32, 1);
            init_args[desc_inner.carry_count] = zero_iter;
            init_types[desc_inner.carry_count] = zero_iter.valueType();

            var scope = try inner.whileScope(
                init_args[0 .. desc_inner.carry_count + 1],
                init_types[0 .. desc_inner.carry_count + 1],
            );
            errdefer scope.abort();

            const before_iter = scope.beforeArg(desc_inner.carry_count) orelse return error.UnsupportedOperation;

            var resolved = std.AutoHashMap(*ir.Value, kernel_root.Value).init(guard_ctx.allocator);
            defer resolved.deinit();
            for (desc_inner.captures[0..desc_inner.capture_count], 0..) |capture, capture_index| {
                try resolved.put(capture, capture_values[capture_index]);
            }

            var varying = std.AutoHashMap(*ir.Value, void).init(guard_ctx.allocator);
            defer varying.deinit();
            for (0..desc_inner.carry_count) |carry_index| {
                try varying.put(desc_inner.block.arguments.items[carry_index], {});
            }
            {
                var scan: ?*ir.Operation = @ptrCast(@alignCast(desc_inner.block.operations.head));
                while (scan) |body_op| : (scan = body_op.next_op) {
                    if (body_op == desc_inner.yield_op) continue;
                    const result = body_op.getResult(0) orelse return error.InvalidArtifact;
                    for (body_op.getOperandValues()) |operand| {
                        if (varying.contains(operand)) {
                            try varying.put(result, {});
                            break;
                        }
                    }
                }
            }

            var hoist: ?*ir.Operation = @ptrCast(@alignCast(desc_inner.block.operations.head));
            while (hoist) |body_op| : (hoist = body_op.next_op) {
                if (body_op == desc_inner.yield_op) continue;
                const result = body_op.getResult(0) orelse return error.InvalidArtifact;
                if (varying.contains(result)) continue;
                try emitInteriorOp(inner, &resolved, body_op, index);
            }

            for (0..desc_inner.carry_count) |carry_index| {
                const before_carry = scope.beforeArg(carry_index) orelse return error.UnsupportedOperation;
                try resolved.put(desc_inner.block.arguments.items[carry_index], before_carry);
            }
            var current: ?*ir.Operation = @ptrCast(@alignCast(desc_inner.block.operations.head));
            while (current) |body_op| : (current = body_op.next_op) {
                if (body_op == desc_inner.yield_op) continue;
                const result = body_op.getResult(0) orelse return error.InvalidArtifact;
                if (!varying.contains(result)) continue;
                try emitInteriorOp(inner, &resolved, body_op, index);
            }

            const yields = desc_inner.yield_op.getOperandValues();
            const pred = resolved.get(yields[0]) orelse return error.UnsupportedOperation;
            var forwarded: [max_carries + 1]kernel_root.Value = undefined;
            for (0..desc_inner.carry_count) |carry_index| {
                forwarded[carry_index] = resolved.get(yields[carry_index + 1]) orelse return error.UnsupportedOperation;
            }

            const next_iter = try inner.add(before_iter, one);
            const below_cap = try inner.compare(.lt, next_iter, max_iters_value);
            const proceed = try inner.and_(pred, below_cap);
            forwarded[desc_inner.carry_count] = next_iter;
            try scope.condition(proceed, forwarded[0 .. desc_inner.carry_count + 1]);

            var afters: [max_carries + 1]kernel_root.Value = undefined;
            for (0..desc_inner.carry_count + 1) |after_index| {
                afters[after_index] = scope.afterArg(after_index) orelse return error.UnsupportedOperation;
            }
            try scope.leave(afters[0 .. desc_inner.carry_count + 1]);

            for (0..desc_inner.carry_count) |carry_index| {
                const result_value = desc_inner.op.getResult(carry_index) orelse return error.InvalidArtifact;
                const result_slot = guard_ctx.buffer_plan.getSlot(result_value) orelse return error.UnsupportedOperation;
                const final_value = scope.result(carry_index) orelse return error.UnsupportedOperation;
                const result_index = if (desc_inner.carry_elements[carry_index] == 1) zero_index else index;
                if (result_slot.id == guard_ctx.outline.output_slot_id) {
                    try inner.storeIndex(final_value, guard_ctx.abi.output(inner), result_index);
                    continue;
                }
                if (result_value.first_use == null) continue;
                const result_input = externalInputIndex(guard_ctx.outline, result_slot.id) orelse return error.UnsupportedOperation;
                try inner.storeIndex(final_value, guard_ctx.abi.input(inner, result_input), result_index);
            }
        }
    }.run);
}

fn emitInteriorOp(
    inner: anytype,
    resolved: *std.AutoHashMap(*ir.Value, kernel_root.Value),
    body_op: *ir.Operation,
    index: kernel_root.Value,
) !void {
    const result = body_op.getResult(0) orelse return error.InvalidArtifact;
    if (isName(body_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
        if (valueHasDTypeAndElements(result, .key, 1)) return;
        const value = try common.splatConstantValue(inner, body_op);
        try resolved.put(result, value);
        return;
    }
    if (isName(body_op.name.name, dialect_mod.AccyDialect.BroadcastOp.operation_name) or
        isName(body_op.name.name, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name))
    {
        const source = body_op.getOperand(0) orelse return error.InvalidArtifact;
        const value = resolved.get(source) orelse return error.UnsupportedOperation;
        try resolved.put(result, value);
        return;
    }
    if (isName(body_op.name.name, dialect_mod.AccyDialect.ReshapeOp.operation_name)) {
        const source = body_op.getOperand(0) orelse return error.InvalidArtifact;
        const value = resolved.get(source) orelse return error.UnsupportedOperation;
        try resolved.put(result, value);
        return;
    }
    if (supportedKernelCall(body_op, valueElementCount(result) catch return error.InvalidArtifact)) |_| {
        const value = try emitPhiloxKeyCounterUniform(inner, resolved, body_op, index);
        try resolved.put(result, value);
        return;
    }
    const kind = generated_elementwise.kernelForOperation(body_op) orelse return error.UnsupportedOperation;
    const operands = body_op.getOperandValues();
    if (operands.len > 3) return error.UnsupportedOperation;
    var inputs: [3]kernel_root.Value = undefined;
    for (operands, 0..) |operand, operand_index| {
        inputs[operand_index] = resolved.get(operand) orelse return error.UnsupportedOperation;
    }
    var dtype_arena_buffer: [160]u8 = undefined;
    var dtype_arena = alloc_fixed.FixedBuffer.init(dtype_arena_buffer[0..]);
    const result_type = dialect_mod.decodeTensorType(dtype_arena.allocator(), result.type) catch return error.InvalidArtifact;
    const value = generated_elementwise.emitElementwiseValue(inner, kind, inputs[0..operands.len], result_type.dtype, body_op) catch |err| return common.mapGeneratedKernelError(err);
    try resolved.put(result, value);
}

fn emitPhiloxKeyCounterUniform(
    inner: anytype,
    resolved: *std.AutoHashMap(*ir.Value, kernel_root.Value),
    body_op: *ir.Operation,
    index: kernel_root.Value,
) common.LoweringError!kernel_root.Value {
    const result = body_op.getResult(0) orelse return error.InvalidArtifact;
    const spec = supportedKernelCall(body_op, valueElementCount(result) catch return error.InvalidArtifact) orelse return error.UnsupportedOperation;
    const operands = body_op.getOperandValues();
    const seed = try keyConstantWords(inner, operands[0]);
    const counter = resolved.get(operands[1]) orelse return error.UnsupportedOperation;
    const element = inner.cast(index, .i32) catch |err| return mapKernelBuildError(err);
    const words = random.block.philoxWords(
        inner,
        spec.rounds,
        element,
        counter,
        seed[0],
        seed[1],
    ) catch |err| return mapGeneratedKernelError(err);
    return switch (spec.dtype) {
        .f32 => random.block.outputWord(inner, .f32, words[0]) catch |err| return mapGeneratedKernelError(err),
        .i32 => random.block.outputWord(inner, .i32, words[0]) catch |err| return mapGeneratedKernelError(err),
        else => error.UnsupportedOperation,
    };
}

fn keyConstantWords(inner: anytype, value: *ir.Value) common.LoweringError![2]kernel_root.Value {
    const def_any = value.getDefiningOp() orelse return error.UnsupportedOperation;
    const def_op: *ir.Operation = @ptrCast(@alignCast(def_any));
    if (!isName(def_op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) return error.UnsupportedOperation;
    const constant = dialect_mod.AccyDialect.ConstantOp{ .op = def_op };
    const payload = constant.getPayload() orelse return error.InvalidArtifact;
    if (payload.len != @sizeOf(u64)) return error.InvalidArtifact;
    var bits: u64 = undefined;
    @memcpy(std.mem.asBytes(&bits), payload[0..@sizeOf(u64)]);
    const lo: u32 = @truncate(bits);
    const hi: u32 = @truncate(bits >> 32);
    return .{
        inner.constantInt(.i32, @as(i32, @bitCast(lo))) catch |err| return mapKernelBuildError(err),
        inner.constantInt(.i32, @as(i32, @bitCast(hi))) catch |err| return mapKernelBuildError(err),
    };
}

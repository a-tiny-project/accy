const std = @import("std");
const abi = @import("gpu_abi");
const choir = @import("../../../root.zig");
const gpu = @import("../../../dialects/gpu/root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const ArithDialect = dialects.ArithDialect;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const GpuDialect = gpu.GpuDialect;
const MemrefDialect = dialects.MemrefDialect;
const ScfDialect = dialects.ScfDialect;
const Dimension = gpu.Dimension;

pub const LowerOptions = struct {
    entry_name: []const u8,
    vector_width: ?u32 = null,
};

/// Lowers the kernel `options.entry_name` to a host function that runs one
/// range of its launch.
///
/// The launch shape trails the source arguments in the ABI's order: first,
/// upper, grid x y z, threadgroup x y z. The function runs invocations
/// [first, upper), and none when first >= upper, since a loop tests its bound
/// before its first iteration. Machine code cannot assert that a caller kept
/// first <= upper, so the vector path clamps first to upper before it takes
/// `upper - first`, which would otherwise wrap and make the tail rerun
/// invocations that belong to another range.
pub fn lowerKernelToHostLoop(
    allocator: std.mem.Allocator,
    kernel_module: *ir.Operation,
    options: LowerOptions,
) abi.Error!*ir.Operation {
    const source = ir.inspection.functionDefinitionByName(kernel_module, options.entry_name) orelse return error.InvalidArtifact;
    const source_func = FuncDialect.FuncOp{ .op = source };
    if (source_func.getNumResults() != 0) return error.UnsupportedOperation;

    const host_module = BuiltinDialect.ModuleOp.create(kernel_module.getContext(), source.location) catch |err| return loweringError(err);
    errdefer host_module.op.erase();

    const source_args = source_func.getArguments();
    const index_type = ArithDialect.getIndexType(kernel_module.getContext()) catch |err| return loweringError(err);
    const buffer_arg_count = try countBufferArguments(kernel_module.getContext(), source_args);
    const host_arg_types = allocator.alloc(ir.Type, source_args.len + abi.launch_shape_argument_count) catch return error.OutOfMemory;
    defer allocator.free(host_arg_types);
    var buffer_arg_index: usize = 0;
    var scalar_arg_index: usize = buffer_arg_count;
    for (source_args) |argument| {
        const index = if (try isBufferType(kernel_module.getContext(), argument.type)) index: {
            const current = buffer_arg_index;
            buffer_arg_index += 1;
            break :index current;
        } else index: {
            const current = scalar_arg_index;
            scalar_arg_index += 1;
            break :index current;
        };
        host_arg_types[index] = cpuBoundaryType(kernel_module.getContext(), argument.type) catch |err| return loweringError(err);
    }
    for (0..abi.launch_shape_argument_count) |index| {
        host_arg_types[source_args.len + index] = index_type;
    }

    const host_func = FuncDialect.FuncOp.create(
        kernel_module.getContext(),
        source.location,
        options.entry_name,
        host_arg_types,
        &.{},
    ) catch |err| return loweringError(err);
    host_module.getBodyBlock().addOperation(host_func.op) catch |err| return loweringError(err);

    const entry = host_func.getEntryBlock();
    const host_args = host_func.getArguments();
    const mapped_source_args = allocator.alloc(*ir.Value, source_args.len) catch return error.OutOfMemory;
    defer allocator.free(mapped_source_args);
    buffer_arg_index = 0;
    scalar_arg_index = buffer_arg_count;
    for (source_args, 0..) |source_arg, source_index| {
        const index = if (try isBufferType(kernel_module.getContext(), source_arg.type)) index: {
            const current = buffer_arg_index;
            buffer_arg_index += 1;
            break :index current;
        } else index: {
            const current = scalar_arg_index;
            scalar_arg_index += 1;
            break :index current;
        };
        const boundary_value = try cpuBoundaryValue(kernel_module.getContext(), source.location, entry, source_arg.type, host_args[index]);
        mapped_source_args[source_index] = boundary_value;
    }

    const source_block = source_func.getEntryBlock();
    const vectorization = try vectorizationForBlock(allocator, kernel_module.getContext(), source_block, options.vector_width);

    const one = createIndexConstant(kernel_module.getContext(), source.location, 1) catch |err| return loweringError(err);
    entry.addOperation(one.op) catch |err| return loweringError(err);

    const first = host_args[source_args.len];
    const upper = host_args[source_args.len + 1];
    const grid_dims = [3]*ir.Value{
        host_args[source_args.len + 2],
        host_args[source_args.len + 3],
        host_args[source_args.len + 4],
    };
    const threadgroup_dims = [3]*ir.Value{
        host_args[source_args.len + 5],
        host_args[source_args.len + 6],
        host_args[source_args.len + 7],
    };
    const gpu_usage = collectGpuIndexUsage(source_block);

    if (vectorization) |plan| {
        const start = ArithDialect.MinOp.create(kernel_module.getContext(), source.location, first, upper) catch |err| return loweringError(err);
        entry.addOperation(start.op) catch |err| return loweringError(err);
        const vector_step = createIndexConstant(kernel_module.getContext(), source.location, plan.width) catch |err| return loweringError(err);
        entry.addOperation(vector_step.op) catch |err| return loweringError(err);
        const vector_upper = try createVectorUpper(
            kernel_module.getContext(),
            source.location,
            entry,
            start.getResult(),
            upper,
            vector_step.getResult(),
            grid_dims[0],
            threadgroup_dims[0],
        );

        const vector_loop = ScfDialect.ForOp.create(
            kernel_module.getContext(),
            source.location,
            start.getResult(),
            vector_upper,
            vector_step.getResult(),
            &.{},
            &.{},
        ) catch |err| return loweringError(err);
        entry.addOperation(vector_loop.op) catch |err| return loweringError(err);
        try cloneKernelBlockIntoLoop(
            allocator,
            kernel_module.getContext(),
            source.location,
            source_block,
            source_args,
            mapped_source_args,
            vector_loop,
            grid_dims,
            threadgroup_dims,
            gpu_usage,
            plan,
        );

        const tail_loop = ScfDialect.ForOp.create(
            kernel_module.getContext(),
            source.location,
            vector_upper,
            upper,
            one.getResult(),
            &.{},
            &.{},
        ) catch |err| return loweringError(err);
        entry.addOperation(tail_loop.op) catch |err| return loweringError(err);
        try cloneKernelBlockIntoLoop(
            allocator,
            kernel_module.getContext(),
            source.location,
            source_block,
            source_args,
            mapped_source_args,
            tail_loop,
            grid_dims,
            threadgroup_dims,
            gpu_usage,
            null,
        );
    } else {
        const loop = ScfDialect.ForOp.create(
            kernel_module.getContext(),
            source.location,
            first,
            upper,
            one.getResult(),
            &.{},
            &.{},
        ) catch |err| return loweringError(err);
        entry.addOperation(loop.op) catch |err| return loweringError(err);
        try cloneKernelBlockIntoLoop(
            allocator,
            kernel_module.getContext(),
            source.location,
            source_block,
            source_args,
            mapped_source_args,
            loop,
            grid_dims,
            threadgroup_dims,
            gpu_usage,
            null,
        );
    }

    const ret = FuncDialect.ReturnOp.create(kernel_module.getContext(), source.location, &.{}) catch |err| return loweringError(err);
    entry.addOperation(ret.op) catch |err| return loweringError(err);

    ir.verifyOperation(host_module.op, ir.verify.default_options) catch return error.CompilationFailed;
    return host_module.op;
}

/// Where the vector loop over [start, upper) ends: the last multiple of the
/// width past start that stays inside the launch's first row.
///
/// A VECTOR COVERS CONSECUTIVE ELEMENTS ONLY INSIDE ONE ROW. Global x is the
/// linear index modulo the row, grid x times threadgroup x, and the vector
/// load and store index by global x. Below the row, global x equals the
/// linear index whatever the range's start, so the vector loop ends at
/// min(upper, row), raised to start, and the scalar tail runs the rest. The
/// bound needs no compare, whose predicate would register an attribute in a
/// context a caller may have frozen.
fn createVectorUpper(
    ctx: *ir.Context,
    loc: ir.Location,
    entry: *ir.Block,
    start: *ir.Value,
    upper: *ir.Value,
    step: *ir.Value,
    grid_x: *ir.Value,
    threadgroup_x: *ir.Value,
) abi.Error!*ir.Value {
    const row = try createProduct(ctx, loc, entry, grid_x, threadgroup_x);
    const inside = ArithDialect.MinOp.create(ctx, loc, upper, row) catch |err| return loweringError(err);
    entry.addOperation(inside.op) catch |err| return loweringError(err);
    const bound = ArithDialect.MaxOp.create(ctx, loc, inside.getResult(), start) catch |err| return loweringError(err);
    entry.addOperation(bound.op) catch |err| return loweringError(err);
    const span = ArithDialect.SubOp.create(ctx, loc, bound.getResult(), start) catch |err| return loweringError(err);
    entry.addOperation(span.op) catch |err| return loweringError(err);
    const remainder = ArithDialect.RemOp.create(ctx, loc, span.getResult(), step) catch |err| return loweringError(err);
    entry.addOperation(remainder.op) catch |err| return loweringError(err);
    const vector_upper = ArithDialect.SubOp.create(ctx, loc, bound.getResult(), remainder.getResult()) catch |err| return loweringError(err);
    entry.addOperation(vector_upper.op) catch |err| return loweringError(err);
    return vector_upper.getResult();
}

fn cloneKernelBlockIntoLoop(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    loc: ir.Location,
    source_block: *ir.Block,
    source_args: []*ir.Value,
    mapped_source_args: []*ir.Value,
    loop: ScfDialect.ForOp,
    grid_dims: [3]*ir.Value,
    threadgroup_dims: [3]*ir.Value,
    gpu_usage: GpuIndexUsage,
    vectorization: ?VectorizationPlan,
) abi.Error!void {
    var mapping = ir.Mapping.init(allocator);
    defer mapping.deinit();
    try seedSourceArgumentMapping(&mapping, source_args, mapped_source_args);

    const loop_body = loop.getBodyBlock();
    mapping.mapBlock(source_block, loop_body) catch return error.OutOfMemory;
    const gpu_values = try createGpuIndexValues(
        ctx,
        loc,
        loop_body,
        loop.getInductionVar(),
        grid_dims,
        threadgroup_dims,
        gpu_usage,
    );
    if (vectorization) |plan| {
        try cloneBlockIntoVectorHostLoop(
            source_block,
            loop_body,
            &mapping,
            gpu_values,
            plan,
            true,
        );
    } else {
        try cloneBlockIntoHostLoop(
            source_block,
            loop_body,
            &mapping,
            gpu_values,
            .{ .ctx = ctx, .entry = loop.op.parent_block orelse return error.InvalidArtifact, .loop = loop.op },
            true,
        );
    }
}

fn seedSourceArgumentMapping(
    mapping: *ir.Mapping,
    source_args: []*ir.Value,
    mapped_source_args: []*ir.Value,
) abi.Error!void {
    if (source_args.len != mapped_source_args.len) return error.InvalidArtifact;
    for (source_args, mapped_source_args) |source_arg, mapped_source_arg| {
        mapping.mapValue(source_arg, mapped_source_arg) catch return error.OutOfMemory;
    }
}

fn createIndexConstant(ctx: *ir.Context, loc: ir.Location, value: i64) !ArithDialect.ConstantOp {
    const index_type = try ArithDialect.getIndexType(ctx);
    return try ArithDialect.ConstantOp.createInt(ctx, loc, index_type, value);
}

fn cpuBoundaryType(ctx: *ir.Context, typ: ir.Type) !ir.Type {
    if (try ctx.getTypeParamPayload(typ, MemrefDialect.MemrefTypePayload)) |payload| {
        const element_type = payload.element_type orelse return error.InvalidMemrefElementType;
        const attrs = MemrefDialect.MemrefTypeAttrs{
            .alignment = payload.alignment,
            .exclusive = payload.exclusive,
            .indexing = payload.indexing,
        };
        if (payload.size) |size| {
            return try MemrefDialect.getMemrefType1DWithAttrs(ctx, size, element_type, .host, attrs);
        }
        return try MemrefDialect.getMemrefTypeDynamicWithAttrs(ctx, element_type, .host, attrs);
    }
    return switch (cpuScalarBoundaryKind(typ) orelse return typ) {
        .f32 => try ArithDialect.getScalarType(ctx, .i32),
        .f64 => try ArithDialect.getScalarType(ctx, .i64),
        else => typ,
    };
}

fn cpuBoundaryValue(
    ctx: *ir.Context,
    loc: ir.Location,
    entry: *ir.Block,
    source_type: ir.Type,
    boundary_value: *ir.Value,
) abi.Error!*ir.Value {
    switch (cpuScalarBoundaryKind(source_type) orelse return boundary_value) {
        .f32, .f64 => {
            const cast = ArithDialect.BitcastOp.create(ctx, loc, boundary_value, source_type) catch |err| return loweringError(err);
            entry.addOperation(cast.op) catch |err| return loweringError(err);
            return cast.getResult();
        },
        else => return boundary_value,
    }
}

fn cpuScalarBoundaryKind(typ: ir.Type) ?dialects.arith.ScalarKind {
    const type_name = typ.getDialectTypeName() orelse return null;
    return dialects.arith.scalarKindFromTypeName(type_name);
}

fn countBufferArguments(ctx: *ir.Context, args: []*ir.Value) abi.Error!usize {
    var count: usize = 0;
    for (args) |argument| {
        if (try isBufferType(ctx, argument.type)) count += 1;
    }
    return count;
}

fn isBufferType(ctx: *ir.Context, typ: ir.Type) abi.Error!bool {
    return (ctx.getTypeParamPayload(typ, MemrefDialect.MemrefTypePayload) catch |err| return loweringError(err)) != null;
}

const VectorizationPlan = struct {
    width: u32,
};

fn vectorizationForBlock(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    block: *ir.Block,
    width: ?u32,
) abi.Error!?VectorizationPlan {
    const requested = width orelse return null;
    if (requested < 2) return null;
    if (!try canVectorizeBlock(allocator, ctx, block, requested)) return null;
    return .{ .width = requested };
}

fn canVectorizeBlock(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    block: *ir.Block,
    width: u32,
) abi.Error!bool {
    var index_values = std.AutoHashMapUnmanaged(*const ir.Value, void){};
    defer index_values.deinit(allocator);
    var vector_values = std.AutoHashMapUnmanaged(*const ir.Value, void){};
    defer vector_values.deinit(allocator);
    var scalar_values = std.AutoHashMapUnmanaged(*const ir.Value, void){};
    defer scalar_values.deinit(allocator);
    var saw_load = false;
    var saw_store = false;

    for (block.arguments.items) |argument| {
        if ((try packedCpuVectorTypeForScalarType(ctx, argument.type, width)) != null) {
            scalar_values.put(allocator, argument, {}) catch return error.OutOfMemory;
        }
    }

    var iter = block.getOperations();
    while (iter.next()) |op| {
        if (std.mem.eql(u8, op.name.name, FuncDialect.ReturnOp.operation_name)) continue;

        if (std.mem.eql(u8, op.name.name, GpuDialect.GlobalIdxOp.operation_name)) {
            if ((gpuDimension(op) orelse return false) != .x) return false;
            const result = op.getResult(0) orelse return false;
            index_values.put(allocator, result, {}) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.eql(u8, op.name.getDialectNamespace(), GpuDialect.name)) return false;
        if (op.successors.items.len != 0 or op.regions.items.len != 0) return false;

        if (std.mem.eql(u8, op.name.name, MemrefDialect.LoadOp.operation_name)) {
            const load = MemrefDialect.LoadOp{ .op = op };
            if (!index_values.contains(load.getIndex())) return false;
            _ = try packedCpuVectorTypeForScalarType(ctx, load.getResult().type, width) orelse return false;
            vector_values.put(allocator, load.getResult(), {}) catch return error.OutOfMemory;
            saw_load = true;
            continue;
        }

        if (std.mem.eql(u8, op.name.name, MemrefDialect.StoreOp.operation_name)) {
            const store = MemrefDialect.StoreOp{ .op = op };
            if (!index_values.contains(store.getIndex())) return false;
            if (!vector_values.contains(store.getValue())) return false;
            saw_store = true;
            continue;
        }

        if (std.mem.eql(u8, op.name.name, ArithDialect.ConstantOp.operation_name)) {
            const result = op.getResult(0) orelse return false;
            if ((try packedCpuVectorTypeForScalarType(ctx, result.type, width)) == null) return false;
            scalar_values.put(allocator, result, {}) catch return error.OutOfMemory;
            continue;
        }

        if (isVectorizableBinaryOp(op)) {
            const lhs = op.getOperand(0) orelse return false;
            const rhs = op.getOperand(1) orelse return false;
            const result = op.getResult(0) orelse return false;
            _ = try packedCpuVectorTypeForScalarType(ctx, result.type, width) orelse return false;
            const lhs_vector = vector_values.contains(lhs);
            const rhs_vector = vector_values.contains(rhs);
            if (!lhs_vector and !scalar_values.contains(lhs)) return false;
            if (!rhs_vector and !scalar_values.contains(rhs)) return false;
            if (lhs_vector or rhs_vector) {
                vector_values.put(allocator, result, {}) catch return error.OutOfMemory;
            } else {
                scalar_values.put(allocator, result, {}) catch return error.OutOfMemory;
            }
            continue;
        }

        if (isVectorizableUnaryOp(op)) {
            const input = op.getOperand(0) orelse return false;
            const result = op.getResult(0) orelse return false;
            _ = try packedCpuVectorTypeForScalarType(ctx, result.type, width) orelse return false;
            if (vector_values.contains(input)) {
                vector_values.put(allocator, result, {}) catch return error.OutOfMemory;
            } else if (scalar_values.contains(input)) {
                scalar_values.put(allocator, result, {}) catch return error.OutOfMemory;
            } else {
                return false;
            }
            continue;
        }

        return false;
    }

    return saw_load and saw_store;
}

/// Where a kernel's private memory lands in the host function: before the
/// loop, in the function's entry block.
///
/// An invocation's `.local` alloca becomes a `.host` alloca of the same size,
/// element and attributes, as the stage twin maps it (`stage.zig`). The alloca
/// is hoisted out of the loop, so every invocation reuses one frame slot on any
/// backend, and the host function's allocas all stand in its entry block. The
/// reuse is sound because an invocation writes its private memory before it
/// reads it.
const HostLocals = struct {
    ctx: *ir.Context,
    entry: *ir.Block,
    loop: *ir.Operation,

    /// Hoists `op` when it allocates private memory, and says whether it did.
    /// An alloca in any other address space keeps the clone path.
    fn hoist(self: HostLocals, op: *ir.Operation, mapping: *ir.Mapping) abi.Error!bool {
        const source = MemrefDialect.AllocaOp{ .op = op };
        const result = source.getResult();
        const params = MemrefDialect.parseMemrefParams(result.type.getDialectParamKey() orelse return error.InvalidArtifact) orelse return error.InvalidArtifact;
        if (params.addr_space != .local) return false;
        if (source.getDynamicSize() != null) return error.UnsupportedOperation;
        const size = params.size orelse return error.UnsupportedOperation;
        const element = self.ctx.getDialectTypeFromName(params.element_type_name) catch return error.UnsupportedOperation;
        const host_type = MemrefDialect.getMemrefType1DWithAttrs(self.ctx, size, element, .host, .{
            .alignment = params.alignment,
            .exclusive = params.exclusive,
            .indexing = params.indexing,
        }) catch |err| return loweringError(err);
        const host = MemrefDialect.AllocaOp.createStatic(self.ctx, op.location, host_type) catch |err| return loweringError(err);
        self.entry.insertBefore(host.op, self.loop) catch |err| return loweringError(err);
        mapping.mapValue(result, host.getResult()) catch return error.OutOfMemory;
        return true;
    }
};

fn cloneBlockIntoHostLoop(
    source: *ir.Block,
    dest: *ir.Block,
    mapping: *ir.Mapping,
    gpu_values: GpuIndexValues,
    locals: HostLocals,
    function_body: bool,
) abi.Error!void {
    var iter = source.getOperations();
    while (iter.next()) |op| {
        if (std.mem.eql(u8, op.name.name, FuncDialect.ReturnOp.operation_name)) {
            if (!function_body) return error.UnsupportedOperation;
            const yield_op = ScfDialect.YieldOp.create(op.getContext(), op.location, &.{}) catch |err| return loweringError(err);
            dest.addOperation(yield_op.op) catch |err| return loweringError(err);
            continue;
        }

        if (std.mem.eql(u8, op.name.name, MemrefDialect.AllocaOp.operation_name)) {
            if (try locals.hoist(op, mapping)) continue;
        }

        if (std.mem.eql(u8, op.name.name, GpuDialect.GlobalIdxOp.operation_name)) {
            const global_index = gpu_values.global.value(gpuDimension(op) orelse return error.UnsupportedOperation) orelse return error.UnsupportedOperation;
            const result = op.getResult(0) orelse return error.UnsupportedOperation;
            mapping.mapValue(result, global_index) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.eql(u8, op.name.name, GpuDialect.ThreadIdxOp.operation_name)) {
            const thread_index = gpu_values.thread.value(gpuDimension(op) orelse return error.UnsupportedOperation) orelse return error.UnsupportedOperation;
            const result = op.getResult(0) orelse return error.UnsupportedOperation;
            mapping.mapValue(result, thread_index) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.eql(u8, op.name.name, GpuDialect.BlockIdxOp.operation_name)) {
            const block_index = gpu_values.block.value(gpuDimension(op) orelse return error.UnsupportedOperation) orelse return error.UnsupportedOperation;
            const result = op.getResult(0) orelse return error.UnsupportedOperation;
            mapping.mapValue(result, block_index) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.eql(u8, op.name.name, GpuDialect.BlockDimOp.operation_name)) {
            const block_dim = gpu_values.threadgroupValue(gpuDimension(op) orelse return error.UnsupportedOperation);
            const result = op.getResult(0) orelse return error.UnsupportedOperation;
            mapping.mapValue(result, block_dim) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.eql(u8, op.name.name, GpuDialect.GridDimOp.operation_name)) {
            const grid_dim = gpu_values.gridValue(gpuDimension(op) orelse return error.UnsupportedOperation);
            const result = op.getResult(0) orelse return error.UnsupportedOperation;
            mapping.mapValue(result, grid_dim) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.eql(u8, op.name.getDialectNamespace(), GpuDialect.name)) {
            return error.UnsupportedOperation;
        }

        if (op.successors.items.len != 0) return error.UnsupportedOperation;

        const has_regions = op.regions.items.len != 0;
        const cloned = op.cloneWithoutRegionsMapped(mapping, .{ .clone_operands = !has_regions }) catch |err| return loweringError(err);
        errdefer cloned.erase();
        dest.addOperation(cloned) catch |err| return loweringError(err);
        for (op.regions.items, 0..) |*source_region, region_index| {
            const dest_region = &cloned.regions.items[region_index];
            var source_block = source_region.blocks.head;
            while (source_block) |block| : (source_block = block.next) {
                const cloned_block = dest_region.addBlock() catch |err| return loweringError(err);
                mapping.mapBlock(block, cloned_block) catch return error.OutOfMemory;
                cloned_block.arguments.ensureTotalCapacity(cloned_block.allocator, block.arguments.items.len) catch return error.OutOfMemory;
                for (block.arguments.items) |argument| {
                    const cloned_argument = cloned_block.addArgument(argument.type, .unknown) catch |err| return loweringError(err);
                    mapping.mapValue(argument, cloned_argument) catch return error.OutOfMemory;
                }
            }

            source_block = source_region.blocks.head;
            while (source_block) |block| : (source_block = block.next) {
                const cloned_block = mapping.lookupBlock(block) orelse return error.UnsupportedOperation;
                try cloneBlockIntoHostLoop(block, cloned_block, mapping, gpu_values, locals, false);
            }
        }
        if (has_regions) try replaceOperandsMapped(op, cloned, mapping);
    }
}

fn cloneBlockIntoVectorHostLoop(
    source: *ir.Block,
    dest: *ir.Block,
    mapping: *ir.Mapping,
    gpu_values: GpuIndexValues,
    plan: VectorizationPlan,
    function_body: bool,
) abi.Error!void {
    var iter = source.getOperations();
    while (iter.next()) |op| {
        if (std.mem.eql(u8, op.name.name, FuncDialect.ReturnOp.operation_name)) {
            if (!function_body) return error.UnsupportedOperation;
            const yield_op = ScfDialect.YieldOp.create(op.getContext(), op.location, &.{}) catch |err| return loweringError(err);
            dest.addOperation(yield_op.op) catch |err| return loweringError(err);
            continue;
        }

        if (std.mem.eql(u8, op.name.name, GpuDialect.GlobalIdxOp.operation_name)) {
            if ((gpuDimension(op) orelse return error.UnsupportedOperation) != .x) return error.UnsupportedOperation;
            const global_index = gpu_values.global.x orelse return error.UnsupportedOperation;
            const result = op.getResult(0) orelse return error.UnsupportedOperation;
            mapping.mapValue(result, global_index) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.eql(u8, op.name.name, MemrefDialect.LoadOp.operation_name)) {
            try cloneVectorLoad(op, dest, mapping, plan.width);
            continue;
        }

        if (std.mem.eql(u8, op.name.name, MemrefDialect.StoreOp.operation_name)) {
            try cloneVectorStore(op, dest, mapping);
            continue;
        }

        if (std.mem.eql(u8, op.name.name, ArithDialect.ConstantOp.operation_name)) {
            try cloneScalarOperationIntoVectorLoop(op, dest, mapping);
            continue;
        }

        if (isVectorizableBinaryOp(op)) {
            try cloneVectorBinaryOp(op, dest, mapping, plan.width);
            continue;
        }

        if (isVectorizableUnaryOp(op)) {
            try cloneVectorUnaryOp(op, dest, mapping, plan.width);
            continue;
        }

        return error.UnsupportedOperation;
    }
}

fn cloneVectorLoad(
    op: *ir.Operation,
    dest: *ir.Block,
    mapping: *ir.Mapping,
    width: u32,
) abi.Error!void {
    const load = MemrefDialect.LoadOp{ .op = op };
    const memref = mapping.lookupValue(load.getMemref()) orelse return error.UnsupportedOperation;
    const index = mapping.lookupValue(load.getIndex()) orelse return error.UnsupportedOperation;
    const result_type = try packedCpuVectorTypeForScalarType(op.getContext(), load.getResult().type, width) orelse return error.UnsupportedOperation;
    var cloned = MemrefDialect.LoadOp.create(op.getContext(), op.location, memref, index, result_type) catch |err| return loweringError(err);
    dest.addOperation(cloned.op) catch |err| return loweringError(err);
    mapping.mapValue(load.getResult(), cloned.getResult()) catch return error.OutOfMemory;
}

fn cloneVectorStore(
    op: *ir.Operation,
    dest: *ir.Block,
    mapping: *ir.Mapping,
) abi.Error!void {
    const store = MemrefDialect.StoreOp{ .op = op };
    const value = mapping.lookupValue(store.getValue()) orelse return error.UnsupportedOperation;
    const memref = mapping.lookupValue(store.getMemref()) orelse return error.UnsupportedOperation;
    const index = mapping.lookupValue(store.getIndex()) orelse return error.UnsupportedOperation;
    const cloned = MemrefDialect.StoreOp.create(op.getContext(), op.location, value, memref, index) catch |err| return loweringError(err);
    dest.addOperation(cloned.op) catch |err| return loweringError(err);
}

fn cloneVectorBinaryOp(
    op: *ir.Operation,
    dest: *ir.Block,
    mapping: *ir.Mapping,
    width: u32,
) abi.Error!void {
    const lhs = mapping.lookupValue(op.getOperand(0) orelse return error.UnsupportedOperation) orelse return error.UnsupportedOperation;
    const rhs = mapping.lookupValue(op.getOperand(1) orelse return error.UnsupportedOperation) orelse return error.UnsupportedOperation;
    const source_result = op.getResult(0) orelse return error.UnsupportedOperation;
    const result_type = try packedCpuVectorTypeForScalarType(op.getContext(), source_result.type, width) orelse return error.UnsupportedOperation;
    if (!lhs.type.eql(result_type) and !rhs.type.eql(result_type)) {
        try cloneScalarOperationIntoVectorLoop(op, dest, mapping);
        return;
    }

    const vector_lhs = try vectorOperandForMappedValue(op, dest, lhs, result_type, width);
    const vector_rhs = try vectorOperandForMappedValue(op, dest, rhs, result_type, width);

    var state = ir.Operation.State.init(op.name.name, op.location);
    state.addOperands(&.{ vector_lhs, vector_rhs });
    state.addTypes(&.{result_type});
    const cloned = op.getContext().createOperation(state) catch |err| return loweringError(err);
    errdefer cloned.erase();
    dest.addOperation(cloned) catch |err| return loweringError(err);
    const result = cloned.getResult(0) orelse return error.UnsupportedOperation;
    mapping.mapValue(source_result, result) catch return error.OutOfMemory;
}

fn cloneVectorUnaryOp(
    op: *ir.Operation,
    dest: *ir.Block,
    mapping: *ir.Mapping,
    width: u32,
) abi.Error!void {
    const input = mapping.lookupValue(op.getOperand(0) orelse return error.UnsupportedOperation) orelse return error.UnsupportedOperation;
    const source_result = op.getResult(0) orelse return error.UnsupportedOperation;
    const result_type = try packedCpuVectorTypeForScalarType(op.getContext(), source_result.type, width) orelse return error.UnsupportedOperation;
    if (!input.type.eql(result_type)) {
        try cloneScalarOperationIntoVectorLoop(op, dest, mapping);
        return;
    }

    var state = ir.Operation.State.init(op.name.name, op.location);
    state.addOperands(&.{input});
    state.addTypes(&.{result_type});
    const cloned = op.getContext().createOperation(state) catch |err| return loweringError(err);
    errdefer cloned.erase();
    dest.addOperation(cloned) catch |err| return loweringError(err);
    const result = cloned.getResult(0) orelse return error.UnsupportedOperation;
    mapping.mapValue(source_result, result) catch return error.OutOfMemory;
}

fn cloneScalarOperationIntoVectorLoop(
    op: *ir.Operation,
    dest: *ir.Block,
    mapping: *ir.Mapping,
) abi.Error!void {
    const cloned = op.cloneWithoutRegionsMapped(mapping, .{ .clone_operands = true }) catch |err| return loweringError(err);
    errdefer cloned.erase();
    dest.addOperation(cloned) catch |err| return loweringError(err);
}

fn vectorOperandForMappedValue(
    op: *ir.Operation,
    dest: *ir.Block,
    mapped: *ir.Value,
    result_type: ir.Type,
    width: u32,
) abi.Error!*ir.Value {
    if (mapped.type.eql(result_type)) return mapped;
    const vector_type = try packedCpuVectorTypeForScalarType(op.getContext(), mapped.type, width) orelse return error.UnsupportedOperation;
    if (!vector_type.eql(result_type)) return error.UnsupportedOperation;
    const splat = ArithDialect.SplatOp.create(op.getContext(), op.location, mapped, result_type) catch |err| return loweringError(err);
    dest.addOperation(splat.op) catch |err| return loweringError(err);
    return splat.getResult();
}

fn isVectorizableBinaryOp(op: *const ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, ArithDialect.AddOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.SubOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.MulOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.DivOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.MinOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.MaxOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.AndOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.OrOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.XorOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.ShlOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.ShrOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.UshrOp.operation_name);
}

fn isVectorizableUnaryOp(op: *const ir.Operation) bool {
    return std.mem.eql(u8, op.name.name, ArithDialect.NegOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.NotOp.operation_name) or
        std.mem.eql(u8, op.name.name, ArithDialect.PopCountOp.operation_name);
}

fn packedCpuVectorTypeForScalarType(ctx: *ir.Context, scalar_type: ir.Type, width: u32) abi.Error!?ir.Type {
    const scalar_name = scalar_type.getDialectTypeName() orelse return null;
    const scalar_kind = dialects.arith.scalarKindFromTypeName(scalar_name) orelse return null;
    switch (scalar_kind) {
        .f32, .i32, .u32 => if (width != 4) return null,
        .f64, .i64, .u64 => if (width != 2) return null,
        else => return null,
    }
    const vector_name = dialects.arith.vectorTypeNameForElement(width, scalar_name) orelse return null;
    return ctx.getDialectTypeFromName(vector_name) catch |err| return loweringError(err);
}

fn replaceOperandsMapped(source: *ir.Operation, dest: *ir.Operation, mapping: *ir.Mapping) abi.Error!void {
    var operands: []*ir.Value = &.{};
    defer if (operands.len != 0) dest.allocator.free(operands);
    if (source.operand_values.len != 0) {
        operands = dest.allocator.alloc(*ir.Value, source.operand_values.len) catch return error.OutOfMemory;
        for (source.operand_values, 0..) |operand, index| {
            operands[index] = mapping.lookupOrDefaultValue(operand);
        }
    }
    dest.replaceOperands(operands) catch |err| return loweringError(err);
}

const DimensionUsage = struct {
    x: bool = false,
    y: bool = false,
    z: bool = false,

    fn add(self: *DimensionUsage, dim: Dimension) void {
        switch (dim) {
            .x => self.x = true,
            .y => self.y = true,
            .z => self.z = true,
        }
    }

    fn addAll(self: *DimensionUsage, other: DimensionUsage) void {
        self.x = self.x or other.x;
        self.y = self.y or other.y;
        self.z = self.z or other.z;
    }

    fn contains(self: DimensionUsage, dim: Dimension) bool {
        return switch (dim) {
            .x => self.x,
            .y => self.y,
            .z => self.z,
        };
    }
};

const GpuIndexUsage = struct {
    global: DimensionUsage = .{},
    thread: DimensionUsage = .{},
    block: DimensionUsage = .{},
    block_dim: DimensionUsage = .{},
    grid_dim: DimensionUsage = .{},

    fn merge(self: *GpuIndexUsage, other: GpuIndexUsage) void {
        self.global.addAll(other.global);
        self.thread.addAll(other.thread);
        self.block.addAll(other.block);
        self.block_dim.addAll(other.block_dim);
        self.grid_dim.addAll(other.grid_dim);
    }

    fn derived(self: GpuIndexUsage) DimensionUsage {
        var result = DimensionUsage{};
        result.addAll(self.global);
        result.addAll(self.thread);
        result.addAll(self.block);
        return result;
    }
};

const DimensionValues = struct {
    x: ?*ir.Value = null,
    y: ?*ir.Value = null,
    z: ?*ir.Value = null,

    fn value(self: DimensionValues, dim: Dimension) ?*ir.Value {
        return switch (dim) {
            .x => self.x,
            .y => self.y,
            .z => self.z,
        };
    }

    fn set(self: *DimensionValues, dim: Dimension, new_value: *ir.Value) void {
        switch (dim) {
            .x => self.x = new_value,
            .y => self.y = new_value,
            .z => self.z = new_value,
        }
    }
};

const GpuIndexValues = struct {
    grid: [3]*ir.Value,
    threadgroup: [3]*ir.Value,
    global: DimensionValues = .{},
    thread: DimensionValues = .{},
    block: DimensionValues = .{},

    fn gridValue(self: GpuIndexValues, dim: Dimension) *ir.Value {
        return self.grid[dimensionIndex(dim)];
    }

    fn threadgroupValue(self: GpuIndexValues, dim: Dimension) *ir.Value {
        return self.threadgroup[dimensionIndex(dim)];
    }
};

fn collectGpuIndexUsage(block: *ir.Block) GpuIndexUsage {
    var usage = GpuIndexUsage{};
    var iter = block.getOperations();
    while (iter.next()) |op| {
        if (std.mem.eql(u8, op.name.name, GpuDialect.GlobalIdxOp.operation_name)) {
            if (gpuDimension(op)) |dim| usage.global.add(dim);
        } else if (std.mem.eql(u8, op.name.name, GpuDialect.ThreadIdxOp.operation_name)) {
            if (gpuDimension(op)) |dim| usage.thread.add(dim);
        } else if (std.mem.eql(u8, op.name.name, GpuDialect.BlockIdxOp.operation_name)) {
            if (gpuDimension(op)) |dim| usage.block.add(dim);
        } else if (std.mem.eql(u8, op.name.name, GpuDialect.BlockDimOp.operation_name)) {
            if (gpuDimension(op)) |dim| usage.block_dim.add(dim);
        } else if (std.mem.eql(u8, op.name.name, GpuDialect.GridDimOp.operation_name)) {
            if (gpuDimension(op)) |dim| usage.grid_dim.add(dim);
        }
        for (op.regions.items) |*region| {
            var block_iter = region.getBlocks();
            while (block_iter.next()) |child_block| {
                usage.merge(collectGpuIndexUsage(child_block));
            }
        }
    }
    return usage;
}

fn createGpuIndexValues(
    ctx: *ir.Context,
    loc: ir.Location,
    dest: *ir.Block,
    linear: *ir.Value,
    grid: [3]*ir.Value,
    threadgroup: [3]*ir.Value,
    usage: GpuIndexUsage,
) abi.Error!GpuIndexValues {
    var values = GpuIndexValues{
        .grid = grid,
        .threadgroup = threadgroup,
    };
    const derived = usage.derived();
    var y_linear: ?*ir.Value = null;
    var x_extent: ?*ir.Value = null;
    var y_extent: ?*ir.Value = null;

    if (derived.x or derived.y or derived.z) {
        x_extent = try createProduct(ctx, loc, dest, grid[0], threadgroup[0]);
    }
    if (derived.y or derived.z) {
        y_extent = try createProduct(ctx, loc, dest, grid[1], threadgroup[1]);
    }

    if (derived.x) {
        const x = ArithDialect.RemOp.create(ctx, loc, linear, x_extent.?) catch |err| return loweringError(err);
        dest.addOperation(x.op) catch |err| return loweringError(err);
        values.global.x = x.getResult();
        try createThreadBlockValues(ctx, loc, dest, &values, .x, x.getResult());
    }

    if (derived.y or derived.z) {
        const div = ArithDialect.DivOp.create(ctx, loc, linear, x_extent.?) catch |err| return loweringError(err);
        dest.addOperation(div.op) catch |err| return loweringError(err);
        y_linear = div.getResult();
    }

    if (derived.y) {
        const y = ArithDialect.RemOp.create(ctx, loc, y_linear.?, y_extent.?) catch |err| return loweringError(err);
        dest.addOperation(y.op) catch |err| return loweringError(err);
        values.global.y = y.getResult();
        try createThreadBlockValues(ctx, loc, dest, &values, .y, y.getResult());
    }

    if (derived.z) {
        const xy_extent = try createProduct(ctx, loc, dest, x_extent.?, y_extent.?);
        const z = ArithDialect.DivOp.create(ctx, loc, linear, xy_extent) catch |err| return loweringError(err);
        dest.addOperation(z.op) catch |err| return loweringError(err);
        values.global.z = z.getResult();
        try createThreadBlockValues(ctx, loc, dest, &values, .z, z.getResult());
    }

    return values;
}

fn createThreadBlockValues(
    ctx: *ir.Context,
    loc: ir.Location,
    dest: *ir.Block,
    values: *GpuIndexValues,
    dim: Dimension,
    global_value: *ir.Value,
) abi.Error!void {
    const thread_extent = values.threadgroupValue(dim);
    const thread = ArithDialect.RemOp.create(ctx, loc, global_value, thread_extent) catch |err| return loweringError(err);
    dest.addOperation(thread.op) catch |err| return loweringError(err);
    values.thread.set(dim, thread.getResult());

    const block = ArithDialect.DivOp.create(ctx, loc, global_value, thread_extent) catch |err| return loweringError(err);
    dest.addOperation(block.op) catch |err| return loweringError(err);
    values.block.set(dim, block.getResult());
}

fn createProduct(
    ctx: *ir.Context,
    loc: ir.Location,
    dest: *ir.Block,
    lhs: *ir.Value,
    rhs: *ir.Value,
) abi.Error!*ir.Value {
    const product = ArithDialect.MulOp.create(ctx, loc, lhs, rhs) catch |err| return loweringError(err);
    dest.addOperation(product.op) catch |err| return loweringError(err);
    return product.getResult();
}

fn dimensionIndex(dim: Dimension) usize {
    return switch (dim) {
        .x => 0,
        .y => 1,
        .z => 2,
    };
}

fn gpuDimension(op: *const ir.Operation) ?Dimension {
    const attr = op.getAttrAs(ir.Attribute.DialectAttr, "dim") orelse return null;
    return Dimension.fromString(attr.payload);
}

fn loweringError(err: anyerror) abi.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompilationFailed,
    };
}

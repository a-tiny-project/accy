const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const alloc_arena = @import("alloc_arena");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const kernel_library = @import("../kernel/library/root.zig");
const call_preparation = @import("call.zig");
const library_preparation = @import("library.zig");
const dialect_mod = accy_choir.dialect;

const ir = choir.ir;
const rewrite = ir.rewrite;
const passes = choir.passes;
const work = passes.pass.work;

pub const KernelLibraryLowering = library_preparation.KernelLibraryLowering;

pub const Options = struct {
    kernel_library: KernelLibraryLowering = .disabled,
    gather_schedule: ?kernel_library.GatherSchedule = null,
    scatter_schedule: ?kernel_library.ScatterSchedule = null,
    scatter_add_schedule: ?kernel_library.ScatterAddSchedule = null,
    family_tuning: ?*const kernel_library.tuning.FamilyTuningReader = null,

    pub fn eql(self: Options, other: Options) bool {
        return self.kernel_library == other.kernel_library and
            std.meta.eql(self.gather_schedule, other.gather_schedule) and
            std.meta.eql(self.scatter_schedule, other.scatter_schedule) and
            std.meta.eql(self.scatter_add_schedule, other.scatter_add_schedule) and
            self.family_tuning == other.family_tuning;
    }
};

pub const indexing_lowering_pass_name = "accy-choir-indexing-lower";
pub const indexing_lowering_pass_description =
    "Lower semantic Accy indexing operations onto kernel library catalog calls";

const kernel_library_option_choices = [_]passes.PassOptionChoice{
    .{ .name = "disabled" },
    .{ .name = "enabled" },
};

pub const indexing_lowering_pass_options = [_]passes.PassOptionSpec{
    .{
        .name = "kernel-library",
        .description = "Use kernel library calls for supported indexing operations",
        .kind = .choice,
        .choices = &kernel_library_option_choices,
        .default_value = "disabled",
    },
    .{
        .name = "gather-thread-blocks",
        .description = "Thread blocks for selected gather kernels",
        .kind = .unsigned,
    },
    .{
        .name = "scatter-thread-blocks",
        .description = "Thread blocks for selected scatter kernels",
        .kind = .unsigned,
    },
    .{
        .name = "scatter-add-thread-blocks",
        .description = "Thread blocks for selected scatter-add kernels",
        .kind = .unsigned,
    },
};

pub fn indexingLoweringPass() passes.Pass {
    return .{
        .name = indexing_lowering_pass_name,
        .description = indexing_lowering_pass_description,
        .run_fn = runIndexingLoweringPass,
        .work_contract = indexing_work_contract,
    };
}

pub fn indexingLoweringPassWithOptions(options: *const Options) passes.Pass {
    return .{
        .name = indexing_lowering_pass_name,
        .description = indexing_lowering_pass_description,
        .state = @constCast(options),
        .run_with_state_fn = runIndexingLoweringPassWithState,
        .work_contract = indexing_work_contract,
    };
}

pub fn indexingLoweringPassFromOptions(
    allocator: std.mem.Allocator,
    set: passes.PassOptionSet,
) anyerror!passes.Pass {
    const options = try allocator.create(Options);
    errdefer allocator.destroy(options);
    options.* = .{
        .kernel_library = try kernelLibraryLoweringFromText(
            set.choiceValue("kernel-library", "disabled"),
        ),
        .gather_schedule = if (set.get("gather-thread-blocks")) |value| .{
            .thread_blocks = try parseU32Option(value),
        } else null,
        .scatter_schedule = if (set.get("scatter-thread-blocks")) |value| .{
            .thread_blocks = try parseU32Option(value),
        } else null,
        .scatter_add_schedule = if (set.get("scatter-add-thread-blocks")) |value| .{
            .thread_blocks = try parseU32Option(value),
        } else null,
    };
    var pass = indexingLoweringPassWithOptions(options);
    pass.state_deinit_fn = destroyOptions;
    return pass;
}

const indexing_work_contract: work.Contract = .{
    .identity = .{ .name = indexing_lowering_pass_name, .version = 1 },
    .estimate = indexingWork,
};

const IndexingKind = enum {
    gather,
    scatter,
    scatter_add,

    fn fromOperation(op: *ir.Operation) ?IndexingKind {
        inline for (comptime std.meta.tags(IndexingKind)) |kind| {
            if (std.mem.eql(u8, op.name.name, "accy." ++ @tagName(kind))) return kind;
        }
        return null;
    }

    fn scheduled(self: IndexingKind, options: Options) bool {
        return switch (self) {
            .gather => options.gather_schedule != null,
            .scatter => options.scatter_schedule != null,
            .scatter_add => options.scatter_add_schedule != null,
        };
    }
};

const IndexingWork = struct {
    options: Options,
    candidates: u64 = 0,
    tuned: u64 = 0,
    type_bytes: u64 = 0,

    fn visit(self: *IndexingWork, op: *ir.Operation) !ir.WalkResult {
        const kind = IndexingKind.fromOperation(op) orelse return .advance;
        const scheduled = kind.scheduled(self.options);
        if (!scheduled and self.options.family_tuning == null) return .advance;
        if (op.getNumResults() != 1) return .advance;
        if (op.getNumOperands() != @as(usize, if (kind == .gather) 2 else 3)) return .advance;
        self.candidates = try work.add(self.candidates, 1);
        self.tuned = try work.add(self.tuned, @intFromBool(!scheduled));
        for (op.getOperandValues()) |operand| try self.typeBytes(operand.type);
        try self.typeBytes(op.getResult(0).?.type);
        return .advance;
    }

    fn typeBytes(self: *IndexingWork, typ: ir.Type) !void {
        if (typ.getDialectParamKey()) |key| {
            self.type_bytes = try work.add(self.type_bytes, key.len);
        }
    }
};

fn indexingDescriptorStorage() u64 {
    const entry = kernel_library.entry;
    const shape = accy_choir.shape;
    const arrays = 4 * std.ArrayList(shape.Symbol).growCapacity(4) * @sizeOf(shape.Symbol) +
        4 * std.ArrayList(shape.Tensor).growCapacity(4) * @sizeOf(shape.Tensor) +
        4 * std.ArrayList(shape.Fact).growCapacity(4) * @sizeOf(shape.Fact);
    const records = 4 * @sizeOf(entry.Shape) + 10 * @sizeOf(entry.Axis) +
        2 * @sizeOf(entry.ScheduleBinding) + 10 * @sizeOf(shape.Expression) +
        18 * @sizeOf(shape.Term);
    const arena_traffic = 8 * (arrays + records + 512 + 96 * 128);
    return arena_traffic + @sizeOf(alloc_arena.Arena) + @sizeOf(shape.Family) + 64;
}

const TuningWork = struct { input_bytes: u64 = 0, visits: u64 = 0 };

fn indexingTuningWork(options: Options, queries: u64) !TuningWork {
    if (queries == 0) return .{};
    const reader = options.family_tuning.?;
    var bytes = try work.multiply(
        reader.table.records.len,
        @sizeOf(kernel_library.tuning.FamilyTuningRecord),
    );
    for (reader.table.records) |record| bytes = try work.add(bytes, record.target.len);
    return .{
        .input_bytes = bytes,
        .visits = try work.multiply(128, try work.multiply(queries, try work.add(bytes, 1))),
    };
}

fn indexingWork(input: work.Input) !work.Bounds {
    const options: *const Options = if (input.state) |state| @ptrCast(@alignCast(state)) else &.{};
    if (options.kernel_library != .enabled or (options.gather_schedule == null and
        options.scatter_schedule == null and options.scatter_add_schedule == null and
        options.family_tuning == null)) return .{ .work = .{ .structural_visits = 1 } };
    const counts = try work.Census.inspect(input.operation);
    var facts: IndexingWork = .{ .options = options.* };
    _ = try input.operation.walk(.{ .order = .pre_order }, &facts, IndexingWork.visit);
    const descriptors = try work.multiply(
        try work.add(facts.candidates, facts.tuned),
        indexingDescriptorStorage(),
    );
    const spellings = try work.multiply(
        facts.tuned,
        2 * kernel_library.geometry.max_thread_candidates * (128 + 8),
    );
    const decoding = try work.multiply(8, try work.add(
        try work.multiply(facts.type_bytes, @sizeOf(i64)),
        try work.multiply(facts.candidates, 4 * 128 + 64),
    ));
    const queues = try work.multiply(2, try work.arrayListGrowth(*ir.Operation, facts.candidates));
    const bytes = try work.add(
        try work.add(queues, decoding),
        try work.add(descriptors, spellings),
    );
    const tuning = try indexingTuningWork(options.*, facts.tuned);
    const units = try work.add(try work.add(counts.atoms, counts.input_bytes), 1);
    const uses = try work.add(try work.add(counts.values, counts.operands), 1);
    const traversal = try work.multiply(128, try work.multiply(units, uses));
    const processing = try work.add(tuning.visits, try work.multiply(2, descriptors));
    const nodes = try work.multiply(facts.candidates, @sizeOf(ir.Operation) + @sizeOf(ir.Value) +
        3 * @sizeOf(ir.OpOperand) + 8 * @sizeOf(ir.NamedAttribute) + 256 +
        5 * @sizeOf(dialect_mod.AccyDialect.KernelCallScalar));
    return .{
        .work = .{
            .input_bytes = try work.add(counts.input_bytes, tuning.input_bytes),
            .output_bytes = nodes,
            .structural_visits = try work.add(traversal, processing),
            .allocation_capacity = bytes,
        },
        .workspace = bytes,
    };
}

fn destroyOptions(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const options: *Options = @ptrCast(@alignCast(raw orelse return));
    allocator.destroy(options);
}

fn kernelLibraryLoweringFromText(value: []const u8) !KernelLibraryLowering {
    if (std.mem.eql(u8, value, "disabled")) return .disabled;
    if (std.mem.eql(u8, value, "enabled")) return .enabled;
    return error.InvalidPassOptionValue;
}

fn parseU32Option(value: []const u8) !u32 {
    return std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidPassOptionValue;
}

fn runIndexingLoweringPass(pass_ctx: *passes.PassContext) passes.PassResult {
    return runIndexingLoweringWithOptions(pass_ctx, .{});
}

fn runIndexingLoweringPassWithState(
    raw: ?*anyopaque,
    pass_ctx: *passes.PassContext,
) passes.PassResult {
    const options: *const Options = @ptrCast(@alignCast(raw orelse return .failure));
    return runIndexingLoweringWithOptions(pass_ctx, options.*);
}

fn runIndexingLoweringWithOptions(
    pass_ctx: *passes.PassContext,
    options: Options,
) passes.PassResult {
    if (options.kernel_library != .enabled or
        (options.gather_schedule == null and
            options.scatter_schedule == null and
            options.scatter_add_schedule == null and
            options.family_tuning == null))
    {
        pass_ctx.preserveAllAnalyses();
        return .success;
    }

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
                if ((options.gather_schedule != null or options.family_tuning != null) and
                    std.mem.eql(
                        u8,
                        current_op.name.name,
                        dialect_mod.AccyDialect.GatherOp.operation_name,
                    ))
                {
                    var guard = rewriter.insertionGuard();
                    defer guard.deinit();
                    rewriter.setInsertionPointBefore(current_op);
                    if (try lowerKnownKernelLibraryGather(current_op, rewriter, options)) {
                        lowered_count.* += 1;
                    }
                } else if ((options.scatter_schedule != null or options.family_tuning != null) and
                    std.mem.eql(
                        u8,
                        current_op.name.name,
                        dialect_mod.AccyDialect.ScatterOp.operation_name,
                    ))
                {
                    var guard = rewriter.insertionGuard();
                    defer guard.deinit();
                    rewriter.setInsertionPointBefore(current_op);
                    if (try lowerKnownKernelLibraryScatter(current_op, rewriter, options)) {
                        lowered_count.* += 1;
                    }
                } else if ((options.scatter_add_schedule != null or
                    options.family_tuning != null) and
                    std.mem.eql(
                        u8,
                        current_op.name.name,
                        dialect_mod.AccyDialect.ScatterAddOp.operation_name,
                    ))
                {
                    var guard = rewriter.insertionGuard();
                    defer guard.deinit();
                    rewriter.setInsertionPointBefore(current_op);
                    if (try lowerKnownKernelLibraryScatterAdd(current_op, rewriter, options)) {
                        lowered_count.* += 1;
                    }
                }
                current = next;
            }
        }
    }
}

fn lowerKnownKernelLibraryGather(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
    options: Options,
) !bool {
    if (op.getNumResults() != 1) return false;
    const result = op.getResult(0) orelse return false;
    const operands = op.getOperandValues();
    if (operands.len != 2) return false;

    var arena_state = alloc_arena.Arena.init(rewriter.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data_type = try dialect_mod.decodeTensorType(arena, operands[0].type);
    const indices_type = try dialect_mod.decodeTensorType(arena, operands[1].type);
    const output_type = try dialect_mod.decodeTensorType(arena, result.type);
    if (indices_type.dtype != .i32) return false;
    if (output_type.dtype != data_type.dtype) return false;
    if (data_type.dims.len == 0 or indices_type.dims.len != 1) return false;
    if (output_type.dims.len != data_type.dims.len) return false;

    const gather_op = dialect_mod.AccyDialect.GatherOp{ .op = op };
    const axis_value = gather_op.getAxis() orelse return false;
    if (axis_value < 0) return false;
    const axis = std.math.cast(usize, axis_value) orelse return false;
    if (axis >= data_type.dims.len) return false;

    if (!std.mem.eql(i64, output_type.dims[0..axis], data_type.dims[0..axis])) return false;
    if (output_type.dims[axis] != indices_type.dims[0]) return false;
    if (!std.mem.eql(i64, output_type.dims[axis + 1 ..], data_type.dims[axis + 1 ..])) return false;

    const outer = dimsProduct(data_type.dims[0..axis]) orelse return false;
    const axis_size = dimExtent(data_type.dims[axis]) orelse return false;
    const gathered = dimExtent(indices_type.dims[0]) orelse return false;
    const inner = dimsProduct(data_type.dims[axis + 1 ..]) orelse return false;

    var gather_schedule = options.gather_schedule;
    if (gather_schedule == null) {
        const family_tuning = options.family_tuning orelse return false;
        const thread_blocks = (try kernel_library.indexing.resolveGatherSchedule(
            rewriter.allocator,
            family_tuning.*,
            .{
                .outer = outer,
                .axis_size = axis_size,
                .gathered = gathered,
                .inner = inner,
                .dtype = data_type.dtype,
            },
        )) orelse return false;
        gather_schedule = .{ .thread_blocks = thread_blocks };
    }

    var selected = (try kernel_library.selectOwned(rewriter.allocator, .{ .gather = .{
        .dtype = data_type.dtype,
        .outer = outer,
        .axis_size = axis_size,
        .gathered = gathered,
        .inner = inner,
        .schedule = gather_schedule,
    } })) orelse return false;
    defer selected.deinit();

    const instance = kernel_library.indexing.gatherInstanceFromSpecialization(
        selected.descriptor.metadata.specialization,
    ) orelse return false;
    const runtime_scalars = call_preparation.catalogCallScalars(
        5,
        try kernel_library.indexing.gatherRuntimeArguments(instance),
    );
    const result_types = [_]ir.Type{result.type};
    const call = try call_preparation.insertCatalogCall(rewriter, .{
        .descriptor = selected.descriptor,
        .operands = operands,
        .result_types = &result_types,
        .options = .{ .runtime_scalars = runtime_scalars[0..] },
    });
    try rewriter.replaceOpWithValue(op, call.getFirstResult());
    return true;
}

fn lowerKnownKernelLibraryScatter(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
    options: Options,
) !bool {
    if (op.getNumResults() != 1) return false;
    const result = op.getResult(0) orelse return false;
    const operands = op.getOperandValues();
    if (operands.len != 3) return false;

    var arena_state = alloc_arena.Arena.init(rewriter.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data_type = try dialect_mod.decodeTensorType(arena, operands[0].type);
    const indices_type = try dialect_mod.decodeTensorType(arena, operands[1].type);
    const updates_type = try dialect_mod.decodeTensorType(arena, operands[2].type);
    const output_type = try dialect_mod.decodeTensorType(arena, result.type);
    if (indices_type.dtype != .i32) return false;
    if (updates_type.dtype != data_type.dtype) return false;
    if (output_type.dtype != data_type.dtype) return false;
    if (data_type.dims.len == 0 or indices_type.dims.len != 1) return false;
    if (updates_type.dims.len != data_type.dims.len) return false;
    if (output_type.dims.len != data_type.dims.len) return false;

    const scatter_op = dialect_mod.AccyDialect.ScatterOp{ .op = op };
    const axis_value = scatter_op.getAxis() orelse return false;
    if (axis_value < 0) return false;
    const axis = std.math.cast(usize, axis_value) orelse return false;
    if (axis >= data_type.dims.len) return false;

    if (!std.mem.eql(i64, output_type.dims, data_type.dims)) return false;
    if (!std.mem.eql(i64, updates_type.dims[0..axis], data_type.dims[0..axis])) return false;
    if (updates_type.dims[axis] != indices_type.dims[0]) return false;
    if (!std.mem.eql(i64, updates_type.dims[axis + 1 ..], data_type.dims[axis + 1 ..])) {
        return false;
    }

    const outer = dimsProduct(data_type.dims[0..axis]) orelse return false;
    const axis_size = dimExtent(data_type.dims[axis]) orelse return false;
    const updates = dimExtent(indices_type.dims[0]) orelse return false;
    const inner = dimsProduct(data_type.dims[axis + 1 ..]) orelse return false;

    var scatter_schedule = options.scatter_schedule;
    if (scatter_schedule == null) {
        const family_tuning = options.family_tuning orelse return false;
        const thread_blocks = (try kernel_library.indexing.resolveScatterSchedule(
            rewriter.allocator,
            family_tuning.*,
            .{
                .outer = outer,
                .axis_size = axis_size,
                .updates = updates,
                .inner = inner,
                .dtype = data_type.dtype,
            },
        )) orelse return false;
        scatter_schedule = .{ .thread_blocks = thread_blocks };
    }

    var selected = (try kernel_library.selectOwned(rewriter.allocator, .{ .scatter = .{
        .dtype = data_type.dtype,
        .outer = outer,
        .axis_size = axis_size,
        .updates = updates,
        .inner = inner,
        .schedule = scatter_schedule,
    } })) orelse return false;
    defer selected.deinit();

    const instance = kernel_library.indexing.scatterInstanceFromSpecialization(
        selected.descriptor.metadata.specialization,
    ) orelse return false;
    const runtime_scalars = call_preparation.catalogCallScalars(
        5,
        try kernel_library.indexing.scatterRuntimeArguments(instance),
    );
    const result_types = [_]ir.Type{result.type};
    const call = try call_preparation.insertCatalogCall(rewriter, .{
        .descriptor = selected.descriptor,
        .operands = operands,
        .result_types = &result_types,
        .options = .{ .runtime_scalars = runtime_scalars[0..] },
    });
    try rewriter.replaceOpWithValue(op, call.getFirstResult());
    return true;
}

fn lowerKnownKernelLibraryScatterAdd(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
    options: Options,
) !bool {
    if (op.getNumResults() != 1) return false;
    const result = op.getResult(0) orelse return false;
    const operands = op.getOperandValues();
    if (operands.len != 3) return false;

    var arena_state = alloc_arena.Arena.init(rewriter.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data_type = try dialect_mod.decodeTensorType(arena, operands[0].type);
    const indices_type = try dialect_mod.decodeTensorType(arena, operands[1].type);
    const updates_type = try dialect_mod.decodeTensorType(arena, operands[2].type);
    const output_type = try dialect_mod.decodeTensorType(arena, result.type);
    if (indices_type.dtype != .i32) return false;
    if (updates_type.dtype != data_type.dtype) return false;
    if (output_type.dtype != data_type.dtype) return false;
    if (data_type.dims.len == 0 or indices_type.dims.len != 1) return false;
    if (updates_type.dims.len != data_type.dims.len) return false;
    if (output_type.dims.len != data_type.dims.len) return false;

    const scatter_add_op = dialect_mod.AccyDialect.ScatterAddOp{ .op = op };
    const axis_value = scatter_add_op.getAxis() orelse return false;
    if (axis_value < 0) return false;
    const axis = std.math.cast(usize, axis_value) orelse return false;
    if (axis >= data_type.dims.len) return false;

    if (!std.mem.eql(i64, output_type.dims, data_type.dims)) return false;
    if (!std.mem.eql(i64, updates_type.dims[0..axis], data_type.dims[0..axis])) return false;
    if (updates_type.dims[axis] != indices_type.dims[0]) return false;
    if (!std.mem.eql(i64, updates_type.dims[axis + 1 ..], data_type.dims[axis + 1 ..])) {
        return false;
    }

    const outer = dimsProduct(data_type.dims[0..axis]) orelse return false;
    const axis_size = dimExtent(data_type.dims[axis]) orelse return false;
    const updates = dimExtent(indices_type.dims[0]) orelse return false;
    const inner = dimsProduct(data_type.dims[axis + 1 ..]) orelse return false;

    var scatter_add_schedule = options.scatter_add_schedule;
    if (scatter_add_schedule == null) {
        const family_tuning = options.family_tuning orelse return false;
        const resolved = (try kernel_library.indexing.resolveScatterAddSchedule(
            rewriter.allocator,
            family_tuning.*,
            .{
                .outer = outer,
                .axis_size = axis_size,
                .updates = updates,
                .inner = inner,
                .dtype = data_type.dtype,
            },
        )) orelse return false;
        scatter_add_schedule = switch (resolved.variant) {
            .direct => .{ .thread_blocks = resolved.threads },
            .shared_bins => .{ .shared_bins = resolved.threads },
        };
    }

    var selected = (try kernel_library.selectOwned(rewriter.allocator, .{ .scatter_add = .{
        .dtype = data_type.dtype,
        .outer = outer,
        .axis_size = axis_size,
        .updates = updates,
        .inner = inner,
        .schedule = scatter_add_schedule,
    } })) orelse return false;
    defer selected.deinit();

    const instance = kernel_library.indexing.scatterAddInstanceFromSpecialization(
        selected.descriptor.metadata.specialization,
    ) orelse return false;
    const runtime_scalars = call_preparation.catalogCallScalars(
        5,
        try kernel_library.indexing.scatterAddRuntimeArguments(instance),
    );
    const result_types = [_]ir.Type{result.type};
    const call = try call_preparation.insertCatalogCall(rewriter, .{
        .descriptor = selected.descriptor,
        .operands = operands,
        .result_types = &result_types,
        .options = .{
            .operand_effects = &.{ .read_write, .read, .read },
            .result_aliases = &.{0},
            .runtime_scalars = runtime_scalars[0..],
        },
    });
    try rewriter.replaceOpWithValue(op, call.getFirstResult());
    return true;
}

fn dimExtent(dim: i64) ?u64 {
    if (dim <= 0) return null;
    return @intCast(dim);
}

fn dimsProduct(dims: []const i64) ?u64 {
    var product: u64 = 1;
    for (dims) |dim| {
        const extent = dimExtent(dim) orelse return null;
        product = std.math.mul(u64, product, extent) catch return null;
    }
    return product;
}

const testing = std.testing;
const semantic = accy_choir.semantic;

const IndexingCase = struct {
    kind: IndexingKind = .gather,
    copies: u32 = 1,
    dtype: gpu_abi.DType = .f32,
    threads: u32 = 4,
    shared: bool = false,

    fn outer(self: IndexingCase) u64 {
        return if (self.shared) 1 else 2;
    }
    fn inner(self: IndexingCase) u64 {
        return if (self.shared) 1 else 3;
    }
    fn entries(self: IndexingCase) u64 {
        return if (self.shared) 128 else 5;
    }

    fn module(self: IndexingCase) !*semantic.SemanticModule {
        var builder = try semantic.Builder.init(testing.allocator, .standard);
        defer builder.deinit();
        const data = try builder.tensor(
            self.dtype,
            &.{ @intCast(self.outer()), 8, @intCast(self.inner()) },
        );
        const indices = try builder.tensor(.i32, &.{@intCast(self.entries())});
        const updates = try builder.tensor(
            self.dtype,
            &.{ @intCast(self.outer()), @intCast(self.entries()), @intCast(self.inner()) },
        );
        const result = if (self.kind == .gather) updates else data;
        const inputs: []const ir.Type = if (self.kind == .gather)
            &.{ data, indices }
        else
            &.{ data, indices, updates };
        var function = try builder.beginFunction("indexing_accounting", inputs, &.{result});
        var value: *ir.Value = undefined;
        for (0..self.copies) |_| {
            value = switch (self.kind) {
                .gather => try function.gather(
                    function.parameter(0),
                    function.parameter(1),
                    result,
                    1,
                ),
                .scatter => try function.scatter(
                    function.parameter(0),
                    function.parameter(1),
                    function.parameter(2),
                    result,
                    1,
                ),
                .scatter_add => try function.scatterAdd(
                    function.parameter(0),
                    function.parameter(1),
                    function.parameter(2),
                    result,
                    1,
                ),
            };
        }
        try function.return_(&.{value});
        try function.finish();
        return builder.finish();
    }

    fn options(self: IndexingCase) Options {
        var result: Options = .{ .kernel_library = .enabled };
        switch (self.kind) {
            .gather => result.gather_schedule = .{ .thread_blocks = self.threads },
            .scatter => result.scatter_schedule = .{ .thread_blocks = self.threads },
            .scatter_add => result.scatter_add_schedule = if (self.shared)
                .{ .shared_bins = self.threads }
            else
                .{ .thread_blocks = self.threads },
        }
        return result;
    }

    fn gather(self: IndexingCase) kernel_library.indexing.Gather {
        return .{
            .dtype = self.dtype,
            .outer = self.outer(),
            .axis_size = 8,
            .gathered = self.entries(),
            .inner = self.inner(),
            .threads = self.threads,
        };
    }

    fn scatter(self: IndexingCase) kernel_library.indexing.Scatter {
        return .{
            .dtype = self.dtype,
            .outer = self.outer(),
            .axis_size = 8,
            .updates = self.entries(),
            .inner = self.inner(),
            .threads = self.threads,
        };
    }

    fn scatterAdd(self: IndexingCase) kernel_library.indexing.ScatterAdd {
        return .{
            .dtype = self.dtype,
            .outer = self.outer(),
            .axis_size = 8,
            .updates = self.entries(),
            .inner = self.inner(),
            .threads = self.threads,
            .variant = if (self.shared) .shared_bins else .direct,
        };
    }

    fn query(self: IndexingCase) kernel_library.CatalogQuery {
        const config = self.options();
        return switch (self.kind) {
            .gather => .{ .gather = .{
                .dtype = self.dtype,
                .outer = self.outer(),
                .axis_size = 8,
                .gathered = self.entries(),
                .inner = self.inner(),
                .schedule = config.gather_schedule,
            } },
            .scatter => .{ .scatter = .{
                .dtype = self.dtype,
                .outer = self.outer(),
                .axis_size = 8,
                .updates = self.entries(),
                .inner = self.inner(),
                .schedule = config.scatter_schedule,
            } },
            .scatter_add => .{ .scatter_add = .{
                .dtype = self.dtype,
                .outer = self.outer(),
                .axis_size = 8,
                .updates = self.entries(),
                .inner = self.inner(),
                .schedule = config.scatter_add_schedule,
            } },
        };
    }

    fn target(self: IndexingCase) ![]u8 {
        return switch (self.kind) {
            .gather => kernel_library.indexing.gatherFamilyTarget(testing.allocator, self.gather()),
            .scatter => kernel_library.indexing.scatterFamilyTarget(
                testing.allocator,
                self.scatter(),
            ),
            .scatter_add => kernel_library.indexing.scatterAddFamilyTarget(
                testing.allocator,
                self.scatterAdd(),
            ),
        };
    }

    fn tuningKey(self: IndexingCase, device: u64) !kernel_library.tuning.FamilyTuningKey {
        return switch (self.kind) {
            .gather => kernel_library.indexing.gatherFamilyTuningKey(
                testing.allocator,
                device,
                self.gather(),
            ),
            .scatter => kernel_library.indexing.scatterFamilyTuningKey(
                testing.allocator,
                device,
                self.scatter(),
            ),
            .scatter_add => kernel_library.indexing.scatterAddFamilyTuningKey(
                testing.allocator,
                device,
                self.scatterAdd(),
            ),
        };
    }

    fn lastCandidate(self: IndexingCase) IndexingCase {
        const candidates = switch (self.kind) {
            .gather => kernel_library.indexing.gatherThreadCandidatesForTotal(
                self.gather().total(),
            ),
            .scatter => kernel_library.indexing.scatterThreadCandidatesForTotal(
                self.scatter().total(),
            ),
            .scatter_add => kernel_library.indexing.scatterAddThreadCandidatesForTotal(
                self.scatterAdd().total(),
            ),
        };
        var result = self;
        result.threads = candidates.slice()[candidates.count - 1];
        return result;
    }

    fn check(self: IndexingCase, module_: *semantic.SemanticModule, lowered: bool) !void {
        try module_.verify();
        var witness: IndexingWitness = .{ .case = self };
        _ = try module_.choir_module.walk(
            .{ .order = .pre_order },
            &witness,
            IndexingWitness.visit,
        );
        try testing.expectEqual(@as(u64, if (lowered) 0 else self.copies), witness.originals);
        try testing.expectEqual(@as(u64, if (lowered) self.copies else 0), witness.calls);
    }
};

const IndexingWitness = struct {
    case: IndexingCase,
    originals: u64 = 0,
    calls: u64 = 0,

    fn visit(self: *IndexingWitness, op: *ir.Operation) !ir.WalkResult {
        if (IndexingKind.fromOperation(op) != null) self.originals += 1;
        if (!std.mem.eql(u8, op.name.name, "accy.kernel_call")) return .advance;
        self.calls += 1;
        const expected = try self.case.target();
        defer testing.allocator.free(expected);
        const target = op.getAttr("target").?.cast(ir.Attribute.DialectAttr).?.payload;
        try testing.expectEqualStrings(expected, target);
        const scalars = (try dialect_mod.AccyDialect.kernelCallRuntimeScalars(op)).?;
        const total = self.case.outer() * self.case.inner() *
            @as(u64, if (self.case.kind == .scatter) 8 else self.case.entries());
        const values = [_]u64{
            self.case.outer(), 8, self.case.entries(), self.case.inner(), total,
        };
        try testing.expectEqual(values.len, scalars.count);
        for (values, scalars.slice()) |value, scalar| {
            try testing.expectEqual(.u32, scalar.kind);
            try testing.expectEqual(value, scalar.bits);
        }
        const effects = op.getAttr("operand_effects").?.cast(ir.Attribute.DialectAttr).?.payload;
        const aliases = op.getAttr("result_aliases").?.cast(ir.Attribute.DialectAttr).?.payload;
        const write = self.case.kind == .scatter_add;
        const effect: accy_choir.semantics.KernelOperandEffect = if (write) .read_write else .read;
        try testing.expectEqual(@backingInt(effect), effects[0]);
        const alias = std.mem.bytesToValue(i64, aliases[0..8]);
        try testing.expectEqual(@as(i64, if (write) 0 else -1), alias);
        return .advance;
    }
};

fn checkIndexingAccounting(admitted: bool, constructor: u32) !void {
    const allocator = testing.allocator;
    const revision = choir.product.revision;
    const fixture: IndexingCase = .{};
    const module = try fixture.module();
    defer module.deinit();
    const root = module.choir_module;
    const before = try choir.bytecode.encodeModule(allocator, root);
    defer allocator.free(before);
    const options: Options = switch (constructor) {
        0 => .{},
        3 => .{ .kernel_library = .enabled },
        else => fixture.options(),
    };
    const bounds = try indexingWork(.{ .operation = root, .state = &options });
    var allowance = revision.WorkVector.uniform(1 << 40);
    if (!admitted) allowance.structural_visits = bounds.work.structural_visits - 1;
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = allowance,
        .workspace = 1 << 24,
        .events = 4,
    }, &.{.{ .name = indexing_lowering_pass_name, .version = 1 }});
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
        0 => indexingLoweringPass(),
        1, 3 => indexingLoweringPassWithOptions(&options),
        2 => try indexingLoweringPassFromOptions(allocator, .{ .assignments = &.{
            .{ .name = "kernel-library", .value = "enabled" },
            .{ .name = "gather-thread-blocks", .value = "4" },
        } }),
        else => unreachable,
    });
    const result = manager.runWithAnalysisCache(root, module.context(), &cache, .{});
    try testing.expectEqual(if (admitted) passes.PassResult.success else .failure, result);
    if (admitted) {
        try ledger.producersComplete();
        try testing.expect(!ledger.view().missing_work_contract);
        try fixture.check(module, constructor == 1 or constructor == 2);
    } else {
        try testing.expectEqual(.exhausted, ledger.view().outcome);
        try testing.expectEqual(@as(u64, 0), manager.stats.pass_runs);
    }
    if (!admitted or constructor == 0 or constructor == 3) {
        const after = try choir.bytecode.encodeModule(allocator, root);
        defer allocator.free(after);
        try testing.expectEqualSlices(u8, before, after);
    }
}

fn checkIndexingStorage(fixture: IndexingCase, options: Options, lowered: bool) !void {
    const allocator = testing.allocator;
    const module = try fixture.module();
    defer module.deinit();
    const bounds = try indexingWork(.{ .operation = module.choir_module, .state = &options });
    const bytes = try allocator.alloc(u8, @intCast(bounds.workspace));
    defer allocator.free(bytes);
    var storage = @import("alloc_fixed").Tracked.init(bytes);
    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var context = passes.PassContext.init(module.choir_module, module.context(), allocator, &cache);
    defer context.deinit();
    context.allocator = storage.allocator();
    defer context.allocator = allocator;
    const result = runIndexingLoweringWithOptions(&context, options);
    try testing.expect(!storage.exhausted);
    try testing.expectEqual(null, module.context().exhaustedSegment());
    try testing.expectEqual(.success, result);
    try testing.expect(storage.status().high_water_bytes <= bounds.workspace);
    try fixture.check(module, lowered);
}

const indexing_descriptor_cases = [_]IndexingCase{
    .{},
    .{ .kind = .scatter },
    .{ .kind = .scatter_add },
    .{ .kind = .scatter_add, .shared = true },
    .{ .dtype = .f16 },
    .{ .kind = .scatter, .dtype = .f16 },
    .{ .kind = .scatter_add, .dtype = .i32 },
    .{ .kind = .scatter_add, .dtype = .i32, .shared = true },
};

fn checkIndexingTuning(fixture_: IndexingCase, mode: enum { hit, miss, stale, precedence }) !void {
    const fixture = fixture_.lastCandidate();
    const caps = familyTuningTestCapabilities();
    const device = kernel_library.tuning.deviceFingerprint(caps);
    const key = try fixture.tuningKey(device);
    const target = try fixture.target();
    defer testing.allocator.free(target);
    var records: [129]kernel_library.tuning.FamilyTuningRecord = undefined;
    for (&records, 0..) |*record, index| {
        record.* = .{
            .key = key,
            .target = target,
            .winner_median_ns = 1,
            .runner_up_median_ns = 2,
            .sample_count = 3,
        };
        record.key.device_fingerprint = device +% index +% 1;
    }
    records[128].key = key;
    if (mode == .stale) records[128].target = "unavailable.target";
    const reader = kernel_library.tuning.FamilyTuningReader.init(
        caps,
        .{ .records = if (mode == .miss) records[0..128] else &records },
    );
    var options: Options = .{ .kernel_library = .enabled, .family_tuning = &reader };
    if (mode == .precedence) {
        options = fixture_.options();
        options.family_tuning = &reader;
    }
    if (mode == .hit and fixture.kind == .gather) {
        try checkTuningCharge(fixture, options, false);
        try checkTuningCharge(fixture, options, true);
    }
    const expected = if (mode == .precedence) fixture_ else fixture;
    try checkIndexingStorage(expected, options, mode == .hit or mode == .precedence);
}

fn checkTuningCharge(fixture: IndexingCase, options: Options, admitted: bool) !void {
    const allocator = testing.allocator;
    const module = try fixture.module();
    defer module.deinit();
    const root = module.choir_module;
    const before = try choir.bytecode.encodeModule(allocator, root);
    defer allocator.free(before);
    var small_reader = options.family_tuning.?.*;
    small_reader.table.records = small_reader.table.records[0..1];
    var small_options = options;
    small_options.family_tuning = &small_reader;
    const small = try indexingWork(.{ .operation = root, .state = &small_options });
    const revision = choir.product.revision;
    var allowance = revision.WorkVector.uniform(1 << 40);
    if (!admitted) allowance.structural_visits = small.work.structural_visits;
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = allowance,
        .workspace = 1 << 24,
        .events = 4,
    }, &.{.{ .name = indexing_lowering_pass_name, .version = 1 }});
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
    try manager.addPass(indexingLoweringPassWithOptions(&options));
    const result = manager.runWithAnalysisCache(root, module.context(), &cache, .{});
    try testing.expectEqual(if (admitted) passes.PassResult.success else .failure, result);
    if (admitted) {
        try ledger.producersComplete();
        try testing.expect(!ledger.view().missing_work_contract);
        try testing.expectEqual(@as(u64, 1), ledger.view().executed.counters.pass_runs);
        try fixture.check(module, true);
    } else {
        try testing.expectEqual(.exhausted, ledger.view().outcome);
        try testing.expectEqual(@as(u64, 0), manager.stats.pass_runs);
        const after = try choir.bytecode.encodeModule(allocator, root);
        defer allocator.free(after);
        try testing.expectEqualSlices(u8, before, after);
    }
}

fn gatherTestModule(allocator: std.mem.Allocator, dtype: gpu_abi.DType) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const data_ty = try builder.tensor(dtype, &.{ 2, 8, 3 });
    const indices_ty = try builder.tensor(.i32, &.{5});
    const out_ty = try builder.tensor(dtype, &.{ 2, 5, 3 });
    var fb = try builder.beginFunction(
        "indexing_lowering_gather",
        &.{ data_ty, indices_ty },
        &.{out_ty},
    );
    const out = try fb.gather(fb.parameter(0), fb.parameter(1), out_ty, 1);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn scatterTestModule(allocator: std.mem.Allocator, dtype: gpu_abi.DType) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const data_ty = try builder.tensor(dtype, &.{ 2, 8, 3 });
    const indices_ty = try builder.tensor(.i32, &.{5});
    const updates_ty = try builder.tensor(dtype, &.{ 2, 5, 3 });
    var fb = try builder.beginFunction(
        "indexing_lowering_scatter",
        &.{ data_ty, indices_ty, updates_ty },
        &.{data_ty},
    );
    const out = try fb.scatter(fb.parameter(0), fb.parameter(1), fb.parameter(2), data_ty, 1);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn scatterAddTestModule(
    allocator: std.mem.Allocator,
    dtype: gpu_abi.DType,
) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const data_ty = try builder.tensor(dtype, &.{ 2, 8, 3 });
    const indices_ty = try builder.tensor(.i32, &.{5});
    const updates_ty = try builder.tensor(dtype, &.{ 2, 5, 3 });
    var fb = try builder.beginFunction(
        "indexing_lowering_scatter_add",
        &.{ data_ty, indices_ty, updates_ty },
        &.{data_ty},
    );
    const out = try fb.scatterAdd(fb.parameter(0), fb.parameter(1), fb.parameter(2), data_ty, 1);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn familyTuningTestCapabilities() gpu.BackendCapabilities {
    return .{ .identity = .{
        .backend = .cuda,
        .family = .nvidia_cuda,
        .name = "pass-test-device",
        .vendor_id = 0x10de,
        .device_id = 0x2684,
    } };
}

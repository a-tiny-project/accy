const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const alloc_arena = @import("alloc_arena");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const kernel_library = @import("../kernel/library/root.zig");
const kernel_selection = @import("../kernel/logical/selection/root.zig");
const call_preparation = @import("call.zig");
const library_preparation = @import("library.zig");
const dialect_mod = accy_choir.dialect;

const ir = choir.ir;
const rewrite = ir.rewrite;
const passes = choir.passes;
const work = passes.pass.work;
const Strategy = accy_choir.einsum.Strategy;

pub const KernelLibraryLowering = library_preparation.KernelLibraryLowering;

pub const Options = struct {
    strategy: Strategy = .auto,
    exact_state_limit: usize = accy_choir.einsum.default_exact_state_limit,
    beam_width: usize = 64,
    auto_beam_width: usize = accy_choir.einsum.default_auto_beam_width,
    kernel_library: KernelLibraryLowering = .disabled,
    matrix_product_schedule: ?kernel_library.MatrixProductSchedule = null,
    matrix_product_tuning: ?kernel_library.linalg.MatrixProductScheduleReader = null,
    family_tuning: ?*const kernel_library.tuning.FamilyTuningReader = null,

    pub fn eql(self: Options, other: Options) bool {
        return self.strategy == other.strategy and
            self.exact_state_limit == other.exact_state_limit and
            self.beam_width == other.beam_width and
            self.auto_beam_width == other.auto_beam_width and
            self.kernel_library == other.kernel_library and
            std.meta.eql(self.matrix_product_schedule, other.matrix_product_schedule) and
            matrixProductTuningEql(self.matrix_product_tuning, other.matrix_product_tuning) and
            self.family_tuning == other.family_tuning;
    }
};

fn matrixProductTuningEql(
    lhs: ?kernel_library.linalg.MatrixProductScheduleReader,
    rhs: ?kernel_library.linalg.MatrixProductScheduleReader,
) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return lhs.?.eql(rhs.?);
}

pub const einsum_lowering_pass_name = "accy-choir-einsum-lower";
pub const einsum_lowering_pass_description =
    "Lower semantic Accy einsum operations into planned tensor contractions";

const strategy_option_choices = [_]passes.PassOptionChoice{
    .{ .name = "auto" },
    .{ .name = "left-to-right" },
    .{ .name = "greedy" },
    .{ .name = "beam" },
    .{ .name = "anytime" },
    .{ .name = "optimal" },
};

const kernel_library_option_choices = [_]passes.PassOptionChoice{
    .{ .name = "disabled" },
    .{ .name = "enabled" },
};

pub const einsum_lowering_pass_options = [_]passes.PassOptionSpec{
    .{
        .name = "strategy",
        .description = "Einsum contraction planning strategy",
        .kind = .choice,
        .choices = &strategy_option_choices,
        .default_value = "auto",
    },
    .{
        .name = "exact-state-limit",
        .description = "Maximum exact planner state count",
        .kind = .unsigned,
        .default_value = "262144",
    },
    .{
        .name = "beam-width",
        .description = "Beam planner width",
        .kind = .unsigned,
        .default_value = "64",
    },
    .{
        .name = "auto-beam-width",
        .description = "Beam width used by automatic planning",
        .kind = .unsigned,
        .default_value = "256",
    },
    .{
        .name = "kernel-library",
        .description = "Use kernel library calls for recognized contractions",
        .kind = .choice,
        .choices = &kernel_library_option_choices,
        .default_value = "disabled",
    },
};

pub fn einsumLoweringPass() passes.Pass {
    return .{
        .name = einsum_lowering_pass_name,
        .description = einsum_lowering_pass_description,
        .run_fn = runEinsumLoweringPass,
        .work_contract = einsum_work_contract,
    };
}

pub fn einsumLoweringPassWithOptions(options: *const Options) passes.Pass {
    return .{
        .name = einsum_lowering_pass_name,
        .description = einsum_lowering_pass_description,
        .state = @constCast(options),
        .run_with_state_fn = runEinsumLoweringPassWithState,
        .work_contract = einsum_work_contract,
    };
}

pub fn einsumLoweringPassFromOptions(allocator: std.mem.Allocator, set: passes.PassOptionSet) anyerror!passes.Pass {
    const options = try allocator.create(Options);
    errdefer allocator.destroy(options);
    options.* = .{
        .strategy = try strategyFromText(set.choiceValue("strategy", "auto")),
        .exact_state_limit = try set.unsignedValue(usize, "exact-state-limit", accy_choir.einsum.default_exact_state_limit),
        .beam_width = try set.unsignedValue(usize, "beam-width", 64),
        .auto_beam_width = try set.unsignedValue(usize, "auto-beam-width", accy_choir.einsum.default_auto_beam_width),
        .kernel_library = try kernelLibraryLoweringFromText(set.choiceValue("kernel-library", "disabled")),
    };
    var pass = einsumLoweringPassWithOptions(options);
    pass.state_deinit_fn = destroyOptions;
    return pass;
}

const einsum_work_contract: work.Contract = .{
    .identity = .{ .name = einsum_lowering_pass_name, .version = 1 },
    .estimate = einsumWork,
};

const EinsumWork = struct {
    root: *ir.Operation,
    options: Options,
    candidates: u64 = 0,
    operands: u64 = 0,
    type_bytes: u64 = 0,
    scratch: u64 = 0,
    visits: u64 = 0,
    nodes: u64 = 0,
    types: u64 = 0,
    library_queries: u64 = 0,

    fn visit(self: *EinsumWork, op: *ir.Operation) !ir.WalkResult {
        if (op == self.root or op.getNumResults() != 1) return .advance;
        if (std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.EinsumOp.operation_name)) {
            const text = (dialect_mod.AccyDialect.EinsumOp{ .op = op }).getEquation() orelse
                return .advance;
            try self.equation(op, text.len);
        } else if (self.options.kernel_library == .enabled and
            (self.options.matrix_product_schedule != null or
                self.options.matrix_product_tuning != null or
                self.options.family_tuning != null) and
            op.getNumOperands() == 2 and
            std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.DotGeneralOp.operation_name))
        {
            try self.candidate(op, true);
            self.library_queries = try work.add(self.library_queries, 1);
            self.nodes = try work.add(self.nodes, 1);
        }
        return .advance;
    }

    fn candidate(self: *EinsumWork, op: *ir.Operation, result: bool) !void {
        self.candidates = try work.add(self.candidates, 1);
        self.operands = try work.add(self.operands, op.getNumOperands());
        for (op.getOperandValues()) |operand| try self.typeBytes(operand.type);
        if (result) try self.typeBytes(op.getResult(0).?.type);
    }

    fn typeBytes(self: *EinsumWork, typ: ir.Type) !void {
        if (typ.getDialectParamKey()) |key| {
            self.type_bytes = try work.add(self.type_bytes, key.len);
        }
    }

    fn equation(self: *EinsumWork, op: *ir.Operation, text_bytes: usize) !void {
        const library = self.options.kernel_library == .enabled;
        try self.candidate(op, library);
        const count = op.getNumOperands();
        const parsing = try accy_choir.einsum.parseBounds(text_bytes, count);
        self.scratch = try work.add(self.scratch, parsing.allocation_capacity);
        self.visits = try work.add(self.visits, parsing.structural_visits);
        if (count == 0 or count > 63) return;
        const planning: accy_choir.einsum.Options = .{
            .strategy = self.options.strategy,
            .exact_state_limit = self.options.exact_state_limit,
            .beam_width = self.options.beam_width,
            .auto_beam_width = self.options.auto_beam_width,
        };
        const lowering = try accy_choir.einsum.loweringBounds(count);
        self.scratch = try work.add(self.scratch, try work.add(
            try planning.storageBound(count),
            lowering.scratch_bytes,
        ));
        self.visits = try work.add(self.visits, try work.add(
            try planning.workBound(count),
            lowering.structural_visits,
        ));
        self.nodes = try work.add(self.nodes, lowering.operation_requests);
        self.types = try work.add(self.types, lowering.tensor_type_requests);
        if (library) {
            self.library_queries = try work.add(self.library_queries, 1);
            self.nodes = try work.add(self.nodes, 1);
            self.scratch = try work.add(self.scratch, try work.multiply(
                count,
                @sizeOf(kernel_selection.EinsumOperand) + 62 * @sizeOf(i64) + 128,
            ));
        }
    }
};

/// Sizes the storage needed for the owned description the kernel library returns for one request,
/// including its shapes, axes and schedule bindings (catalog descriptor). The pass declares its
/// costs before it runs so compilation can refuse a pass that would exceed the caller's limits, and
/// this work bound charges descriptor storage once per library request and once per tuning request.
/// The value covers the four matrix families the package authors: matrix product, matrix-vector
/// product, batched matrix product and outer product, including the names of their schedule tiles
/// and lanes and the copies each family makes. The largest descriptor is the batched matrix
/// product, which holds four shapes, six schedule bindings and ten axes. The storage adds room for
/// 64 expressions and 128 terms on top of that to cover the tensor dimensions, facts and runtime
/// sizes copied into a descriptor. The work bound multiplies the value by the number of library and
/// tuning requests.
fn einsumDescriptorStorage() u64 {
    const entry = kernel_library.entry;
    const shape = accy_choir.shape;
    const arrays = 4 * std.ArrayList(shape.Symbol).growCapacity(4) * @sizeOf(shape.Symbol) +
        4 * std.ArrayList(shape.Tensor).growCapacity(4) * @sizeOf(shape.Tensor) +
        4 * std.ArrayList(shape.Fact).growCapacity(4) * @sizeOf(shape.Fact);
    const records = 4 * @sizeOf(entry.Shape) + 10 * @sizeOf(entry.Axis) +
        6 * @sizeOf(entry.ScheduleBinding) + @sizeOf(entry.Reduction) +
        64 * @sizeOf(shape.Expression) + 128 * @sizeOf(shape.Term);
    return 8 * (arrays + records + 2048 + 128 * 128) +
        @sizeOf(alloc_arena.Arena) + @sizeOf(shape.Family) + 128;
}

const EinsumTuningWork = struct {
    input_bytes: u64 = 0,
    visits: u64 = 0,
    family_queries: u64 = 0,
};

fn einsumTuningWork(options: Options, queries: u64) !EinsumTuningWork {
    if (queries == 0 or options.matrix_product_schedule != null) return .{};
    var result: EinsumTuningWork = .{};
    if (options.matrix_product_tuning) |reader| {
        var bytes = try work.add(@sizeOf(@TypeOf(reader)), reader.device.name.len);
        if (reader.device.driver_version) |driver| bytes = try work.add(bytes, driver.len);
        bytes = try work.add(bytes, try work.multiply(
            reader.records.len,
            @sizeOf(kernel_library.tuning.MatrixProductFamilyScheduleTuningRecord),
        ));
        result.input_bytes = try work.add(result.input_bytes, bytes);
    }
    if (options.family_tuning) |reader| {
        result.family_queries = queries;
        var bytes = try work.add(@sizeOf(@TypeOf(reader.*)), try work.multiply(
            reader.table.records.len,
            @sizeOf(kernel_library.tuning.FamilyTuningRecord),
        ));
        for (reader.table.records) |record| bytes = try work.add(bytes, record.target.len);
        result.input_bytes = try work.add(result.input_bytes, bytes);
    }
    result.visits = try work.multiply(128, try work.multiply(
        queries,
        try work.add(result.input_bytes, 1),
    ));
    return result;
}

fn einsumWorkspace(facts: EinsumWork, tuning: EinsumTuningWork) !u64 {
    const dimensions = try work.multiply(facts.type_bytes, 2 * @sizeOf(i64));
    const shapes = try work.multiply(facts.operands, @sizeOf([]const u64) + 256);
    const frames = try work.multiply(facts.candidates, 1024);
    const decoding = try work.add(dimensions, try work.add(shapes, frames));
    const arenas = try work.multiply(8, try work.add(facts.scratch, decoding));
    const replacement = facts.options.matrix_product_schedule != null or
        facts.options.matrix_product_tuning != null or facts.options.family_tuning != null;
    const selections = try work.multiply(
        facts.library_queries,
        @as(u64, if (replacement) 8 else 4),
    );
    const descriptors = try work.multiply(
        try work.add(selections, tuning.family_queries),
        einsumDescriptorStorage(),
    );
    const spellings = try work.multiply(
        tuning.family_queries,
        kernel_library.geometry.max_thread_candidates * (128 + 8),
    );
    const calls = try work.multiply(
        facts.library_queries,
        2 * @sizeOf(accy_choir.semantics.KernelOperandEffect) + @sizeOf(?usize) + 256,
    );
    const queues = try work.add(
        try work.arrayListGrowth(*ir.Operation, facts.nodes),
        try work.arrayListGrowth(*ir.Operation, facts.candidates),
    );
    return work.add(
        try work.add(arenas, descriptors),
        try work.add(try work.add(spellings, calls), queues),
    );
}

fn einsumWork(input: work.Input) !work.Bounds {
    const options: *const Options = if (input.state) |state| @ptrCast(@alignCast(state)) else &.{};
    const counts = try work.Census.inspect(input.operation);
    var facts: EinsumWork = .{ .root = input.operation, .options = options.* };
    _ = try input.operation.walk(.{ .order = .pre_order }, &facts, EinsumWork.visit);
    const tuning = try einsumTuningWork(options.*, facts.library_queries);
    const workspace = try einsumWorkspace(facts, tuning);
    const nodes = try work.multiply(facts.nodes, @sizeOf(ir.Operation) + @sizeOf(ir.Value) +
        2 * @sizeOf(ir.OpOperand) + 8 * @sizeOf(ir.NamedAttribute) + 4 * 62 * @sizeOf(i64) + 512);
    const type_bytes = try work.multiply(facts.types, @sizeOf(ir.Type.DialectTypeStorage) +
        62 * 21 + 128);
    const emitted = try work.add(facts.nodes, 1);
    const units = try work.add(try work.add(counts.atoms, counts.input_bytes), emitted);
    const uses = try work.add(try work.add(counts.values, counts.operands), emitted);
    const traversal = try work.multiply(128, try work.multiply(units, uses));
    const catalog = try work.multiply(facts.library_queries, einsumDescriptorStorage());
    const factories = try work.multiply(128, try work.add(type_bytes, catalog));
    const processing = try work.add(facts.visits, try work.add(tuning.visits, factories));
    return .{
        .work = .{
            .input_bytes = try work.add(counts.input_bytes, tuning.input_bytes),
            .output_bytes = try work.add(nodes, type_bytes),
            .structural_visits = try work.add(traversal, processing),
            .allocation_capacity = workspace,
        },
        .workspace = workspace,
    };
}

fn destroyOptions(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const options: *Options = @ptrCast(@alignCast(raw orelse return));
    allocator.destroy(options);
}

fn strategyFromText(value: []const u8) !Strategy {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "left-to-right")) return .left_to_right;
    if (std.mem.eql(u8, value, "greedy")) return .greedy;
    if (std.mem.eql(u8, value, "beam")) return .beam;
    if (std.mem.eql(u8, value, "anytime")) return .anytime;
    if (std.mem.eql(u8, value, "optimal")) return .optimal;
    return error.InvalidPassOptionValue;
}

fn kernelLibraryLoweringFromText(value: []const u8) !KernelLibraryLowering {
    if (std.mem.eql(u8, value, "disabled")) return .disabled;
    if (std.mem.eql(u8, value, "enabled")) return .enabled;
    return error.InvalidPassOptionValue;
}

fn runEinsumLoweringPass(pass_ctx: *passes.PassContext) passes.PassResult {
    return runEinsumLoweringWithOptions(pass_ctx, .{});
}

fn runEinsumLoweringPassWithState(raw: ?*anyopaque, pass_ctx: *passes.PassContext) passes.PassResult {
    const options: *const Options = @ptrCast(@alignCast(raw orelse return .failure));
    return runEinsumLoweringWithOptions(pass_ctx, options.*);
}

fn runEinsumLoweringWithOptions(pass_ctx: *passes.PassContext, options: Options) passes.PassResult {
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
                if (std.mem.eql(u8, current_op.name.name, dialect_mod.AccyDialect.EinsumOp.operation_name)) {
                    var guard = rewriter.insertionGuard();
                    defer guard.deinit();
                    rewriter.setInsertionPointBefore(current_op);
                    if (!(try lowerEinsumOp(current_op, rewriter, options))) return error.InvalidState;
                    lowered_count.* += 1;
                } else if (options.kernel_library == .enabled and
                    (options.matrix_product_schedule != null or
                        options.matrix_product_tuning != null or
                        options.family_tuning != null) and
                    std.mem.eql(u8, current_op.name.name, dialect_mod.AccyDialect.DotGeneralOp.operation_name))
                {
                    var guard = rewriter.insertionGuard();
                    defer guard.deinit();
                    rewriter.setInsertionPointBefore(current_op);
                    if (try lowerKnownKernelLibraryDotGeneral(current_op, rewriter, options)) {
                        lowered_count.* += 1;
                    }
                }
                current = next;
            }
        }
    }
}

fn lowerEinsumOp(op: *ir.Operation, rewriter: *rewrite.PatternRewriter, options: Options) !bool {
    if (!std.mem.eql(u8, op.name.name, dialect_mod.AccyDialect.EinsumOp.operation_name)) return false;
    if (op.getNumResults() != 1) return false;
    const equation_text = (dialect_mod.AccyDialect.EinsumOp{ .op = op }).getEquation() orelse return false;

    var arena_state = alloc_arena.Arena.init(rewriter.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const operands = op.getOperandValues();
    const shapes = try arena.alloc([]const u64, operands.len);
    var dtype: ?gpu_abi.DType = null;
    for (operands, 0..) |operand, i| {
        const tensor_type = try dialect_mod.decodeTensorType(arena, operand.type);
        if (dtype) |known| {
            if (known != tensor_type.dtype) return false;
        } else {
            dtype = tensor_type.dtype;
        }
        const dims = try arena.alloc(u64, tensor_type.dims.len);
        for (tensor_type.dims, 0..) |dim, dim_index| {
            if (dim < 0) return false;
            dims[dim_index] = @intCast(dim);
        }
        shapes[i] = dims;
    }

    var equation = try accy_choir.einsum.parse(arena, equation_text, shapes);
    defer equation.deinit();
    if (options.kernel_library == .enabled) {
        if (try lowerKnownKernelLibraryEinsum(op, rewriter, &equation, operands, dtype orelse return false, options)) |lowered| {
            try rewriter.replaceOpWithValue(op, lowered);
            return true;
        }
    }

    var plan = try accy_choir.einsum.createPlan(arena, &equation, .{
        .strategy = options.strategy,
        .exact_state_limit = options.exact_state_limit,
        .beam_width = options.beam_width,
        .auto_beam_width = options.auto_beam_width,
    });
    defer plan.deinit();

    const lowered = try accy_choir.einsum.lowerPlanWithRewriter(
        arena,
        rewriter,
        &equation,
        &plan,
        operands,
        dtype orelse return false,
    );
    try rewriter.replaceOpWithValue(op, lowered);
    return true;
}

fn lowerKnownKernelLibraryEinsum(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
    equation: *const accy_choir.einsum.Equation,
    operands: []const *ir.Value,
    dtype: gpu_abi.DType,
    options: Options,
) !?*ir.Value {
    const result = op.getResult(0) orelse return null;

    var arena_state = alloc_arena.Arena.init(rewriter.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const output_type = try dialect_mod.decodeTensorType(arena, result.type);
    if (output_type.dtype != dtype) return null;

    const logical_inputs = try arena.alloc(kernel_selection.EinsumOperand, equation.inputs.len);
    for (equation.inputs, logical_inputs) |input, *logical_input| {
        logical_input.* = .{
            .indices = input.indices,
            .dims = try shapeToI64(arena, input.dims),
        };
    }

    const request = kernel_selection.EinsumSelectionRequest{
        .dtype = dtype,
        .inputs = logical_inputs,
        .output_indices = equation.output,
        .output_dims = output_type.dims,
    };
    var selection = (try selectKnownKernelLibraryContraction(rewriter, request, options)) orelse return null;
    defer selection.selected.deinit();

    const result_types = [_]ir.Type{result.type};
    const call = try call_preparation.insertCatalogCall(rewriter, .{
        .descriptor = selection.selected.descriptor.descriptor,
        .operands = operands,
        .result_types = &result_types,
    });
    return call.getFirstResult();
}

const ContractionSelection = struct {
    selected: kernel_selection.OwnedSelectedEinsumKernel,
    scheduled: bool,
};

fn selectKnownKernelLibraryContraction(
    rewriter: *rewrite.PatternRewriter,
    initial_request: kernel_selection.EinsumSelectionRequest,
    options: Options,
) !?ContractionSelection {
    var request = initial_request;
    var selected = (try kernel_selection.selectOwnedEinsumCatalog(rewriter.allocator, request)) orelse return null;
    var selected_owned = true;
    defer if (selected_owned) selected.deinit();
    var scheduled = false;
    if (options.matrix_product_schedule) |matrix_product_schedule| {
        if (selected.kind == .matrix_product) {
            request.schedule = .{ .matrix_product = matrix_product_schedule };
            const replacement = (try kernel_selection.selectOwnedEinsumCatalog(rewriter.allocator, request)) orelse return null;
            selected.deinit();
            selected = replacement;
            scheduled = true;
        }
    } else if (options.matrix_product_tuning) |reader| {
        if (selected.kind == .matrix_product) {
            if (kernel_library.linalg.matrixProductInstanceFromSpecialization(
                selected.descriptor.descriptor.metadata.specialization,
            )) |instance| {
                if (try reader.resolve(instance)) |thread_blocks| {
                    request.schedule = .{ .matrix_product = .{ .thread_blocks = thread_blocks } };
                    const replacement = (try kernel_selection.selectOwnedEinsumCatalog(rewriter.allocator, request)) orelse return null;
                    selected.deinit();
                    selected = replacement;
                    scheduled = true;
                }
            }
        }
    }
    if (!scheduled and options.family_tuning != null) {
        const family_tuning = options.family_tuning.?;
        if (selected.kind == .matrix_product) {
            if (kernel_library.linalg.matrixProductInstanceFromSpecialization(
                selected.descriptor.descriptor.metadata.specialization,
            )) |instance| {
                if (try kernel_library.linalg.resolveMatrixProductSchedule(
                    rewriter.allocator,
                    family_tuning.*,
                    instance,
                )) |thread_blocks| {
                    request.schedule = .{ .matrix_product = .{ .thread_blocks = thread_blocks } };
                    const replacement = (try kernel_selection.selectOwnedEinsumCatalog(rewriter.allocator, request)) orelse return null;
                    selected.deinit();
                    selected = replacement;
                    scheduled = true;
                }
            }
        }
    }
    selected_owned = false;
    return .{ .selected = selected, .scheduled = scheduled };
}

const dot_general_lhs_indices = "mk";
const dot_general_rhs_indices = "kn";
const dot_general_output_indices = "mn";

fn lowerKnownKernelLibraryDotGeneral(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
    options: Options,
) !bool {
    if (op.getNumResults() != 1) return false;
    const result = op.getResult(0) orelse return false;
    const operands = op.getOperandValues();
    if (operands.len != 2) return false;

    const dot = dialect_mod.AccyDialect.DotGeneralOp{ .op = op };
    const lhs_batch = dot.getLhsBatchPayload() orelse return false;
    const rhs_batch = dot.getRhsBatchPayload() orelse return false;
    const lhs_contract = dot.getLhsContractPayload() orelse return false;
    const rhs_contract = dot.getRhsContractPayload() orelse return false;
    if (lhs_batch.len != 0 or rhs_batch.len != 0) return false;
    if (!std.mem.eql(u8, lhs_contract, std.mem.sliceAsBytes(&[_]i64{1}))) return false;
    if (!std.mem.eql(u8, rhs_contract, std.mem.sliceAsBytes(&[_]i64{0}))) return false;

    var arena_state = alloc_arena.Arena.init(rewriter.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lhs_type = try dialect_mod.decodeTensorType(arena, operands[0].type);
    const rhs_type = try dialect_mod.decodeTensorType(arena, operands[1].type);
    const output_type = try dialect_mod.decodeTensorType(arena, result.type);
    if (lhs_type.dtype != rhs_type.dtype or lhs_type.dtype != output_type.dtype) return false;
    if (lhs_type.dims.len != 2 or rhs_type.dims.len != 2 or output_type.dims.len != 2) return false;

    const logical_inputs = [_]kernel_selection.EinsumOperand{
        .{ .indices = dot_general_lhs_indices, .dims = lhs_type.dims },
        .{ .indices = dot_general_rhs_indices, .dims = rhs_type.dims },
    };
    const request = kernel_selection.EinsumSelectionRequest{
        .dtype = lhs_type.dtype,
        .inputs = logical_inputs[0..],
        .output_indices = dot_general_output_indices,
        .output_dims = output_type.dims,
    };
    var selection = (try selectKnownKernelLibraryContraction(rewriter, request, options)) orelse return false;
    defer selection.selected.deinit();
    if (selection.selected.kind != .matrix_product) return false;
    if (options.matrix_product_schedule == null and !selection.scheduled) return false;

    const result_types = [_]ir.Type{result.type};
    const call = try call_preparation.insertCatalogCall(rewriter, .{
        .descriptor = selection.selected.descriptor.descriptor,
        .operands = operands,
        .result_types = &result_types,
    });
    try rewriter.replaceOpWithValue(op, call.getFirstResult());
    return true;
}

fn shapeToI64(allocator: std.mem.Allocator, shape: []const u64) ![]const i64 {
    const dims = try allocator.alloc(i64, shape.len);
    for (shape, 0..) |dim, index| {
        if (dim > @as(u64, @intCast(std.math.maxInt(i64)))) return error.InvalidDimension;
        dims[index] = @intCast(dim);
    }
    return dims;
}

fn findOpNamed(op: *ir.Operation, name: []const u8) ?*ir.Operation {
    if (std.mem.eql(u8, op.name.name, name)) return op;
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                if (findOpNamed(current_op, name)) |found| return found;
                current = current_op.next_op;
            }
        }
    }
    return null;
}

const testing = std.testing;
const semantic = accy_choir.semantic;

test "einsum lowering pass replaces semantic einsum with planned contraction" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 5, 8 });
    const rhs_ty = try builder.tensor(.f32, &.{ 8, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 5, 16 });
    var fb = try builder.beginFunction("einsum_lowering_pass", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "ik,kj->ij");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
}

test "einsum lowering pass selects kernel library matrix product" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 4, 8 });
    const rhs_ty = try builder.tensor(.f32, &.{ 8, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 4, 16 });
    var fb = try builder.beginFunction("einsum_kernel_library_lowering_pass", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "ik,kj->ij");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "einsum lowering pass selects kernel library matrix product family" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 5, 3 });
    const rhs_ty = try builder.tensor(.f32, &.{ 3, 7 });
    const out_ty = try builder.tensor(.f32, &.{ 5, 7 });
    var fb = try builder.beginFunction("einsum_kernel_library_matmul_family_lowering_pass", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "mk,kn->mn");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
    const kernel_call = findOpNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name) orelse {
        return error.TestExpectedKernelCall;
    };
    const target_attr = kernel_call.getAttr("target") orelse return error.TestExpectedKernelCallTarget;
    const target = target_attr.cast(ir.Attribute.DialectAttr) orelse return error.TestExpectedKernelCallTarget;
    try testing.expectEqualStrings("accy.kernel.linalg.matmul_family_7x5_f32", target.payload);
}

test "einsum lowering pass selects scheduled kernel library matrix product family" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 5, 3 });
    const rhs_ty = try builder.tensor(.f32, &.{ 3, 7 });
    const out_ty = try builder.tensor(.f32, &.{ 5, 7 });
    var fb = try builder.beginFunction("einsum_kernel_library_matmul_family_schedule_lowering_pass", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "mk,kn->mn");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{
        .kernel_library = .enabled,
        .matrix_product_schedule = .{ .thread_blocks = .{ .x = 4, .y = 2 } },
    };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
    const kernel_call = findOpNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name) orelse {
        return error.TestExpectedKernelCall;
    };
    const target_attr = kernel_call.getAttr("target") orelse return error.TestExpectedKernelCallTarget;
    const target = target_attr.cast(ir.Attribute.DialectAttr) orelse return error.TestExpectedKernelCallTarget;
    try testing.expectEqualStrings("accy.kernel.linalg.matmul_family_4x2_f32", target.payload);
}

test "einsum lowering pass selects kernel library matrix vector product" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const matrix_ty = try builder.tensor(.f32, &.{ 4, 8 });
    const vector_ty = try builder.tensor(.f32, &.{8});
    const out_ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("einsum_kernel_library_matvec_lowering_pass", &.{ matrix_ty, vector_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "mk,k->m");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ReduceOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "einsum lowering pass selects kernel library outer product" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{4});
    const rhs_ty = try builder.tensor(.f32, &.{3});
    const out_ty = try builder.tensor(.f32, &.{ 4, 3 });
    var fb = try builder.beginFunction("einsum_kernel_library_outer_lowering_pass", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "m,n->mn");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.MulOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "einsum lowering pass selects kernel library transpose" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const input_ty = try builder.tensor(.f32, &.{ 8, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 16, 8 });
    var fb = try builder.beginFunction("einsum_kernel_library_transpose_lowering_pass", &.{input_ty}, &.{out_ty});
    const out = try fb.einsum(&.{fb.parameter(0)}, out_ty, "ij->ji");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "einsum lowering pass selects kernel library scalar sum reduction" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const input_ty = try builder.tensor(.f32, &.{8});
    const out_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("einsum_kernel_library_sum_lowering_pass", &.{input_ty}, &.{out_ty});
    const out = try fb.einsum(&.{fb.parameter(0)}, out_ty, "i->");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ReduceOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "einsum lowering pass selects kernel library scalar dot product" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const input_ty = try builder.tensor(.f32, &.{8});
    const out_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("einsum_kernel_library_dot_lowering_pass", &.{ input_ty, input_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "i,i->");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.MulOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ReduceOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "einsum lowering pass keeps attention-shaped pure einsum generic with kernel library" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const query_ty = try builder.tensor(.f32, &.{ 2, 2, 2 });
    const key_ty = try builder.tensor(.f32, &.{ 2, 3, 2 });
    const value_ty = try builder.tensor(.f32, &.{ 2, 3, 2 });
    const out_ty = try builder.tensor(.f32, &.{ 2, 2, 2 });
    var fb = try builder.beginFunction("einsum_kernel_library_attention_shaped_generic_lowering_pass", &.{ query_ty, key_ty, value_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1), fb.parameter(2) }, out_ty, "bqh,bkh,bkv->bqv");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
    try testing.expect(ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.MulOp.operation_name) > 0);
    try testing.expect(ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ReduceOp.operation_name) > 0);
}

test "einsum lowering pass keeps registered matrix product generic by default" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 4, 8 });
    const rhs_ty = try builder.tensor(.f32, &.{ 8, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 4, 16 });
    var fb = try builder.beginFunction("einsum_registered_matmul_generic_lowering_pass", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "ik,kj->ij");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "einsum lowering pass keeps registered transpose generic by default" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const input_ty = try builder.tensor(.f32, &.{ 8, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 16, 8 });
    var fb = try builder.beginFunction("einsum_registered_transpose_generic_lowering_pass", &.{input_ty}, &.{out_ty});
    const out = try fb.einsum(&.{fb.parameter(0)}, out_ty, "ij->ji");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.TransposeOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

test "einsum lowering pass preserves analyses when no einsum exists" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("einsum_lowering_noop", &.{ ty, ty }, &.{ty});
    const out = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPass());

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

test "einsum lowering pass accepts beam width options" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const a_ty = try builder.tensor(.f32, &.{ 32, 4 });
    const b_ty = try builder.tensor(.f32, &.{ 4, 64 });
    const c_ty = try builder.tensor(.f32, &.{ 4, 3 });
    const d_ty = try builder.tensor(.f32, &.{ 4, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 32, 64, 3, 16 });
    var fb = try builder.beginFunction("einsum_lowering_beam_width", &.{ a_ty, b_ty, c_ty, d_ty }, &.{out_ty});
    const out = try fb.einsum(
        &.{ fb.parameter(0), fb.parameter(1), fb.parameter(2), fb.parameter(3) },
        out_ty,
        "ab,bc,bd,be->acde",
    );
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    var options = Options{ .strategy = .beam, .beam_width = 2 };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.EinsumOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
    try testing.expectEqual(@as(usize, 6), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.BroadcastInDimOp.operation_name));
    try testing.expectEqual(@as(usize, 3), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.MulOp.operation_name));
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.ReduceOp.operation_name));
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

test "einsum lowering pass consults family tuning when schedule is null" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 5, 3 });
    const rhs_ty = try builder.tensor(.f32, &.{ 3, 7 });
    const out_ty = try builder.tensor(.f32, &.{ 5, 7 });
    var fb = try builder.beginFunction("einsum_kernel_library_matmul_family_tuned_lowering_pass", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "mk,kn->mn");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const caps = familyTuningTestCapabilities();
    const device = kernel_library.tuning.deviceFingerprint(caps);
    const probe = kernel_library.linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    const thread_candidates = kernel_library.linalg.matrixProductThreadCandidatesForExtents(probe.m, probe.n);
    try testing.expect(thread_candidates.slice().len >= 2);
    var winner = probe;
    winner.threads = thread_candidates.slice()[0];
    const winner_target = try kernel_library.linalg.matrixProductFamilyTarget(allocator, winner);
    defer allocator.free(winner_target);

    const records = [_]kernel_library.tuning.FamilyTuningRecord{.{
        .key = try kernel_library.linalg.matrixProductFamilyTuningKey(allocator, device, probe),
        .target = winner_target,
        .winner_median_ns = 800,
        .runner_up_median_ns = 1200,
        .sample_count = 30,
    }};
    const reader = kernel_library.tuning.FamilyTuningReader.init(caps, .{ .records = records[0..] });

    var options = Options{
        .kernel_library = .enabled,
        .family_tuning = &reader,
    };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    const kernel_call = findOpNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name) orelse {
        return error.TestExpectedKernelCall;
    };
    const target_attr = kernel_call.getAttr("target") orelse return error.TestExpectedKernelCallTarget;
    const target = target_attr.cast(ir.Attribute.DialectAttr) orelse return error.TestExpectedKernelCallTarget;
    try testing.expectEqualStrings(winner_target, target.payload);
}

test "einsum lowering pass keeps heuristic schedule on family tuning miss" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 5, 3 });
    const rhs_ty = try builder.tensor(.f32, &.{ 3, 7 });
    const out_ty = try builder.tensor(.f32, &.{ 5, 7 });
    var fb = try builder.beginFunction("einsum_kernel_library_matmul_family_tuning_miss_lowering_pass", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "mk,kn->mn");
    try fb.return_(&.{out});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const reader = kernel_library.tuning.FamilyTuningReader.init(familyTuningTestCapabilities(), .{});

    var options = Options{
        .kernel_library = .enabled,
        .family_tuning = &reader,
    };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    const kernel_call = findOpNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name) orelse {
        return error.TestExpectedKernelCall;
    };
    const target_attr = kernel_call.getAttr("target") orelse return error.TestExpectedKernelCallTarget;
    const target = target_attr.cast(ir.Attribute.DialectAttr) orelse return error.TestExpectedKernelCallTarget;
    try testing.expectEqualStrings("accy.kernel.linalg.matmul_family_7x5_f32", target.payload);
}

fn dotGeneralTunedModule(allocator: std.mem.Allocator, name: []const u8) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 5, 3 });
    const rhs_ty = try builder.tensor(.f32, &.{ 3, 7 });
    const out_ty = try builder.tensor(.f32, &.{ 5, 7 });
    var fb = try builder.beginFunction(name, &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.dotGeneral(fb.parameter(0), fb.parameter(1), out_ty, &.{1}, &.{0}, &.{}, &.{});
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

test "einsum lowering pass consults family tuning for dot general on hit" {
    const allocator = testing.allocator;

    const module = try dotGeneralTunedModule(allocator, "dot_general_family_tuning_hit_lowering_pass");
    defer module.deinit();

    const caps = familyTuningTestCapabilities();
    const device = kernel_library.tuning.deviceFingerprint(caps);
    const probe = kernel_library.linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3 };
    const thread_candidates = kernel_library.linalg.matrixProductThreadCandidatesForExtents(probe.m, probe.n);
    try testing.expect(thread_candidates.slice().len >= 1);
    var winner = probe;
    winner.threads = thread_candidates.slice()[0];
    const winner_target = try kernel_library.linalg.matrixProductFamilyTarget(allocator, winner);
    defer allocator.free(winner_target);

    const records = [_]kernel_library.tuning.FamilyTuningRecord{.{
        .key = try kernel_library.linalg.matrixProductFamilyTuningKey(allocator, device, probe),
        .target = winner_target,
        .winner_median_ns = 700,
        .runner_up_median_ns = 1100,
        .sample_count = 30,
    }};
    const reader = kernel_library.tuning.FamilyTuningReader.init(caps, .{ .records = records[0..] });

    var options = Options{
        .kernel_library = .enabled,
        .family_tuning = &reader,
    };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
    const kernel_call = findOpNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name) orelse {
        return error.TestExpectedKernelCall;
    };
    const target_attr = kernel_call.getAttr("target") orelse return error.TestExpectedKernelCallTarget;
    const target = target_attr.cast(ir.Attribute.DialectAttr) orelse return error.TestExpectedKernelCallTarget;
    try testing.expectEqualStrings(winner_target, target.payload);
}

test "einsum lowering pass keeps dot general semantic on family tuning miss" {
    const allocator = testing.allocator;

    const module = try dotGeneralTunedModule(allocator, "dot_general_family_tuning_miss_lowering_pass");
    defer module.deinit();

    const reader = kernel_library.tuning.FamilyTuningReader.init(familyTuningTestCapabilities(), .{});

    var options = Options{
        .kernel_library = .enabled,
        .family_tuning = &reader,
    };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(einsumLoweringPassWithOptions(&options));

    try testing.expectEqual(passes.PassResult.success, pm.run(module.choir_module, module.context()));
    try module.verify();
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.DotGeneralOp.operation_name));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(module.choir_module, dialect_mod.AccyDialect.KernelCallOp.operation_name));
}

const EinsumCase = struct {
    expression: []const u8 = "mk,kn->mn",
    shapes: []const []const i64 = &.{ &.{ 5, 3 }, &.{ 3, 7 } },
    output: []const i64 = &.{ 5, 7 },
    dtype: gpu_abi.DType = .f32,
    copies: u32 = 1,
    dot: bool = false,
    outcome: passes.PassResult = .success,
    target: ?[]const u8 = null,

    fn module(self: EinsumCase) !*semantic.SemanticModule {
        const allocator = testing.allocator;
        var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.testing);
        defer builder.deinit();
        const types = try allocator.alloc(ir.Type, self.shapes.len);
        defer allocator.free(types);
        for (self.shapes, types) |shape, *typ| typ.* = try builder.tensor(self.dtype, shape);
        const result_type = try builder.tensor(self.dtype, self.output);
        var fb = try builder.beginFunction("einsum_work", types, &.{result_type});
        const operands = try allocator.alloc(*ir.Value, types.len);
        defer allocator.free(operands);
        for (operands, 0..) |*operand, index| operand.* = fb.parameter(index);
        var value: *ir.Value = undefined;
        for (0..self.copies) |_| {
            value = if (self.dot)
                try fb.dotGeneral(operands[0], operands[1], result_type, &.{1}, &.{0}, &.{}, &.{})
            else if (self.outcome == .success)
                try fb.einsum(operands, result_type, self.expression)
            else blk: {
                const op = try dialect_mod.AccyDialect.EinsumOp.create(
                    fb.ctx,
                    fb.location,
                    operands,
                    result_type,
                    self.expression,
                );
                try fb.entry.addOperation(op.op);
                break :blk op.getResult();
            };
        }
        try fb.return_(&.{value});
        try fb.finish();
        if (self.outcome == .failure) {
            const unfinished = builder.module.?;
            builder.module = null;
            return unfinished;
        }
        return builder.finish();
    }
};

fn einsumStorageImage(fixture: EinsumCase, options: Options, bounded: bool) ![]u8 {
    const allocator = testing.allocator;
    const module = try fixture.module();
    defer module.deinit();
    const root = module.choir_module;
    const before = try choir.bytecode.encodeModule(allocator, root);
    defer allocator.free(before);
    const bounds = try einsumWork(.{ .operation = root, .state = &options });
    const bytes = try allocator.alloc(u8, @intCast(if (bounded) bounds.workspace else 0));
    defer allocator.free(bytes);
    var buffer = std.heap.FixedBufferAllocator.init(bytes);
    const base = buffer.allocator();
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = base.vtable.alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    };
    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var context = passes.PassContext.init(root, module.context(), allocator, &cache);
    defer context.deinit();
    context.allocator = if (bounded) .{ .ptr = base.ptr, .vtable = &vtable } else allocator;
    defer context.allocator = allocator;
    try testing.expectEqual(fixture.outcome, runEinsumLoweringWithOptions(&context, options));
    if (bounded) try testing.expect(buffer.end_index <= bounds.workspace);
    try testing.expectEqual(null, module.context().exhaustedSegment());
    if (fixture.outcome == .success) try module.verify();
    if (fixture.target) |target| {
        const name = dialect_mod.AccyDialect.KernelCallOp.operation_name;
        try testing.expectEqual(fixture.copies, ir.inspection.countOperationsNamed(root, name));
        const call = findOpNamed(root, name).?;
        const actual = call.getAttr("target").?.cast(ir.Attribute.DialectAttr).?.payload;
        try testing.expectEqualStrings(target, actual);
    }
    const image = try choir.bytecode.encodeModule(allocator, root);
    errdefer allocator.free(image);
    try testing.expect(image.len <= before.len + bounds.work.output_bytes);
    return image;
}

fn checkEinsumStorage(fixture: EinsumCase, options: Options) !void {
    const expected = try einsumStorageImage(fixture, options, false);
    defer testing.allocator.free(expected);
    const actual = try einsumStorageImage(fixture, options, true);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, expected, actual);
}

test "einsum lowering work covers every strategy and generic reduction path" {
    const chain: EinsumCase = .{
        .expression = "ab,bc,cd,de->ea",
        .shapes = &.{ &.{ 2, 3 }, &.{ 3, 4 }, &.{ 4, 5 }, &.{ 5, 6 } },
        .output = &.{ 6, 2 },
    };
    for (comptime std.meta.tags(Strategy)) |strategy| {
        try checkEinsumStorage(chain, .{ .strategy = strategy, .beam_width = 3 });
    }
    try checkEinsumStorage(chain, .{ .exact_state_limit = 0, .beam_width = 3 });
    try checkEinsumStorage(.{
        .expression = "abcd,defg->ga",
        .shapes = &.{ &.{ 2, 3, 4, 5 }, &.{ 5, 6, 7, 8 } },
        .output = &.{ 8, 2 },
        .copies = 17,
    }, .{ .strategy = .left_to_right, .kernel_library = .enabled });
    try checkEinsumStorage(.{ .expression = "->", .shapes = &.{&.{}}, .output = &.{} }, .{});
    try checkEinsumStorage(.{
        .expression = "abc->ca",
        .shapes = &.{&.{ 2, 3, 4 }},
        .output = &.{ 4, 2 },
    }, .{});
    try checkEinsumStorage(.{ .dot = true }, .{});
}

test "einsum lowering work covers static and owned library families" {
    const cases = [_]EinsumCase{
        .{},
        .{ .dtype = .f16 },
        .{ .shapes = &.{ &.{ 8, 8 }, &.{ 8, 8 } }, .output = &.{ 8, 8 } },
        .{
            .expression = "bmk,bkn->bmn",
            .shapes = &.{ &.{ 3, 5, 7 }, &.{ 3, 7, 9 } },
            .output = &.{ 3, 5, 9 },
        },
        .{ .expression = "mk,k->m", .shapes = &.{ &.{ 5, 3 }, &.{3} }, .output = &.{5} },
        .{ .expression = "m,n->mn", .shapes = &.{ &.{5}, &.{7} } },
        .{ .expression = "ij->ji", .shapes = &.{&.{ 8, 8 }}, .output = &.{ 8, 8 } },
        .{ .expression = "i->", .shapes = &.{&.{8}}, .output = &.{} },
        .{ .expression = "i,i->", .shapes = &.{ &.{8}, &.{8} }, .output = &.{} },
    };
    for (cases) |fixture| {
        try checkEinsumStorage(fixture, .{ .kernel_library = .enabled });
        var repeated = fixture;
        repeated.copies = 17;
        try checkEinsumStorage(repeated, .{ .kernel_library = .enabled });
    }
    const scheduled: Options = .{
        .kernel_library = .enabled,
        .matrix_product_schedule = .{ .thread_blocks = .{ .x = 4, .y = 2 } },
    };
    try checkEinsumStorage(.{ .copies = 17 }, scheduled);
    try checkEinsumStorage(.{ .copies = 17, .dot = true }, scheduled);
}

test "einsum lowering work covers maximum label and input cardinalities" {
    const labels = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const dims: [labels.len]i64 = @splat(1);
    const shapes: [63][]const i64 = @splat(&dims);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (shapes, 0..) |_, index| {
        if (index != 0) try text.append(testing.allocator, ',');
        try text.appendSlice(testing.allocator, labels);
    }
    try text.appendSlice(testing.allocator, "->" ++ labels);
    try checkEinsumStorage(.{ .expression = text.items, .shapes = &shapes, .output = &dims }, .{
        .strategy = .left_to_right,
    });
}

fn checkEinsumAccounting(constructor: u32, denied: ?u32) !void {
    const allocator = testing.allocator;
    const revision = choir.product.revision;
    const module = try (EinsumCase{}).module();
    defer module.deinit();
    const root = module.choir_module;
    const before = try choir.bytecode.encodeModule(allocator, root);
    defer allocator.free(before);
    const options: Options = .{ .kernel_library = if (constructor == 0) .disabled else .enabled };
    const bounds = try einsumWork(.{ .operation = root, .state = &options });
    var allowance = revision.WorkVector.uniform(1 << 60);
    var workspace: u64 = 1 << 30;
    if (denied) |dimension| switch (dimension) {
        0 => allowance.structural_visits = bounds.work.structural_visits - 1,
        1 => allowance.allocation_capacity = bounds.work.allocation_capacity - 1,
        2 => allowance.output_bytes = bounds.work.output_bytes - 1,
        3 => workspace = bounds.workspace - 1,
        else => unreachable,
    };
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = allowance,
        .workspace = workspace,
        .events = 4,
    }, &.{.{ .name = einsum_lowering_pass_name, .version = 1 }});
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
        0 => einsumLoweringPass(),
        1 => einsumLoweringPassWithOptions(&options),
        2 => try einsumLoweringPassFromOptions(allocator, .{ .assignments = &.{
            .{ .name = "kernel-library", .value = "enabled" },
        } }),
        else => unreachable,
    });
    const result = manager.runWithAnalysisCache(root, module.context(), &cache, .{});
    try testing.expectEqual(if (denied == null) passes.PassResult.success else .failure, result);
    if (denied != null) {
        try testing.expectEqual(.exhausted, ledger.view().outcome);
        try testing.expectEqual(@as(u64, 0), manager.stats.pass_runs);
        const after = try choir.bytecode.encodeModule(allocator, root);
        defer allocator.free(after);
        try testing.expectEqualSlices(u8, before, after);
    } else {
        try ledger.producersComplete();
        try testing.expect(!ledger.view().missing_work_contract);
        try testing.expectEqual(@as(u64, 1), ledger.view().executed.counters.pass_runs);
        try module.verify();
    }
}

test "einsum lowering work admits all constructors and refuses before mutation" {
    for (0..3) |constructor| {
        try checkEinsumAccounting(@intCast(constructor), null);
        for (0..4) |dimension| {
            try checkEinsumAccounting(@intCast(constructor), @intCast(dimension));
        }
    }
}

test "einsum lowering work preserves failed parse and lowering prefixes" {
    const cases = [_]EinsumCase{
        .{ .expression = "mk,kn", .outcome = .failure },
        .{ .expression = "mk,kn->mn->", .outcome = .failure },
        .{ .expression = "mm,kn->mn", .outcome = .failure },
        .{ .expression = "mk,kn->x", .outcome = .failure },
        .{ .shapes = &.{ &.{ 5, 3 }, &.{ 4, 7 } }, .outcome = .failure },
        .{ .shapes = &.{ &.{ 5, -1 }, &.{ 3, 7 } }, .outcome = .failure },
        .{
            .expression = "ab,cd->",
            .outcome = .failure,
            .output = &.{},
            .shapes = &.{ &.{ 4_000_000_000, 4_000_000_000 }, &.{ 2, 3 } },
        },
    };
    for (cases) |fixture| try checkEinsumStorage(fixture, .{});
    const too_many: [64][]const i64 = @splat(&.{1});
    try checkEinsumStorage(.{
        .expression = "i->i",
        .shapes = &too_many,
        .output = &.{1},
        .outcome = .failure,
    }, .{});
}

const EinsumTuningCase = struct {
    const tuning = kernel_library.tuning;
    const Reader = kernel_library.linalg.MatrixProductScheduleReader;
    const Record = tuning.MatrixProductFamilyScheduleTuningRecord;

    fn instance() kernel_library.linalg.MatrixProduct {
        var value: kernel_library.linalg.MatrixProduct = .{ .m = 5, .n = 7, .k = 3 };
        const candidates = kernel_library.linalg.matrixProductThreadCandidatesForExtents(5, 7);
        value.threads = candidates.slice()[candidates.slice().len - 1];
        return value;
    }

    fn matrixRecord() !Record {
        const value = instance();
        const candidates = kernel_library.linalg.matrixProductThreadCandidatesForExtents(5, 7);
        var threads: [8]tuning.MatrixProductFamilyScheduleThreads = undefined;
        for (candidates.slice(), 0..) |candidate, index| {
            threads[index] = .{ .x = candidate.x, .y = candidate.y };
        }
        return .{
            .key = try tuning.MatrixProductFamilyScheduleTuningKey.init(
                familyTuningTestCapabilities().identity,
                .{
                    .format = .cuda_ptx,
                    .m = 5,
                    .n = 7,
                    .k = 3,
                    .dtype = value.dtype,
                    .accumulation_dtype = value.accumulation_dtype,
                    .family_version = kernel_library.linalg.matrix_product_family_version,
                    .candidates = threads[0..candidates.slice().len],
                },
            ),
            .selection = .{
                .threads = .{ .x = value.threads.x, .y = value.threads.y },
                .winner_median_ns = 1,
                .runner_up_median_ns = 2,
                .sample_count = 3,
            },
        };
    }

    fn matrixReader(records: []const Record) Reader {
        return .{
            .device = familyTuningTestCapabilities().identity,
            .format = .cuda_ptx,
            .records = records,
        };
    }

    fn familyRecord(target: []const u8) !tuning.FamilyTuningRecord {
        return .{
            .key = try kernel_library.linalg.matrixProductFamilyTuningKey(
                testing.allocator,
                tuning.deviceFingerprint(familyTuningTestCapabilities()),
                instance(),
            ),
            .target = target,
            .winner_median_ns = 1,
            .runner_up_median_ns = 2,
            .sample_count = 3,
        };
    }
};

test "einsum lowering work covers matrix and family tuning hits misses and precedence" {
    const allocator = testing.allocator;
    const target = try kernel_library.linalg.matrixProductFamilyTarget(
        allocator,
        EinsumTuningCase.instance(),
    );
    defer allocator.free(target);
    var matrix = [_]EinsumTuningCase.Record{try EinsumTuningCase.matrixRecord()};
    var family = [_]kernel_library.tuning.FamilyTuningRecord{
        try EinsumTuningCase.familyRecord(target),
    };
    const family_reader = kernel_library.tuning.FamilyTuningReader.init(
        familyTuningTestCapabilities(),
        .{ .records = &family },
    );
    for ([_]bool{ false, true }) |dot| {
        const fixture: EinsumCase = .{ .dot = dot, .copies = 17, .target = target };
        var options: Options = .{
            .kernel_library = .enabled,
            .matrix_product_tuning = EinsumTuningCase.matrixReader(&matrix),
            .family_tuning = &family_reader,
        };
        try checkEinsumStorage(fixture, options);
        matrix[0].key.k = 99;
        try checkEinsumStorage(fixture, options);
        family[0].key.device_fingerprint = 0;
        var miss = fixture;
        miss.target = null;
        try checkEinsumStorage(miss, options);
        matrix[0] = try EinsumTuningCase.matrixRecord();
        matrix[0].selection.threads = .{ .x = 99, .y = 99 };
        miss.outcome = .failure;
        try checkEinsumStorage(miss, options);
        options.matrix_product_schedule = .{ .thread_blocks = .{
            .x = EinsumTuningCase.instance().threads.x,
            .y = EinsumTuningCase.instance().threads.y,
        } };
        try checkEinsumStorage(fixture, options);
        matrix[0] = try EinsumTuningCase.matrixRecord();
        family[0] = try EinsumTuningCase.familyRecord(target);
    }
}

test "einsum lowering work charges complete tuning tables and device strings" {
    const allocator = testing.allocator;
    const target = try kernel_library.linalg.matrixProductFamilyTarget(
        allocator,
        EinsumTuningCase.instance(),
    );
    defer allocator.free(target);
    var records: [257]EinsumTuningCase.Record = @splat(try EinsumTuningCase.matrixRecord());
    for (records[0..256]) |*record| record.key.k = 99;
    var family: [257]kernel_library.tuning.FamilyTuningRecord =
        @splat(try EinsumTuningCase.familyRecord(target));
    for (family[0..256]) |*record| record.key.device_fingerprint = 0;
    var family_reader = kernel_library.tuning.FamilyTuningReader.init(
        familyTuningTestCapabilities(),
        .{ .records = &family },
    );
    var options: Options = .{
        .kernel_library = .enabled,
        .matrix_product_tuning = EinsumTuningCase.matrixReader(&records),
        .family_tuning = &family_reader,
    };
    try checkEinsumStorage(.{ .copies = 17, .target = target }, options);
    const small = try einsumTuningWork(.{
        .matrix_product_tuning = EinsumTuningCase.matrixReader(records[256..]),
    }, 17);
    const large = try einsumTuningWork(options, 17);
    try testing.expect(large.input_bytes > small.input_bytes);
    try testing.expect(large.visits > small.visits);
    options.matrix_product_tuning.?.records = records[0..256];
    try checkEinsumStorage(.{ .copies = 17, .target = target }, options);
    const long_name: [4096]u8 = @splat('n');
    options.matrix_product_tuning.?.device.name = &long_name;
    options.matrix_product_tuning.?.device.driver_version = &long_name;
    family[0].target = &long_name;
    const longer = try einsumTuningWork(options, 17);
    try testing.expect(longer.input_bytes > large.input_bytes);
    try testing.expect(longer.visits > large.visits);
    try checkEinsumStorage(.{ .copies = 17, .target = target }, options);
    options.matrix_product_schedule = .{ .thread_blocks = .{ .x = 4, .y = 2 } };
    try testing.expectEqualDeep(EinsumTuningWork{}, try einsumTuningWork(options, 17));
    try testing.expectEqualDeep(EinsumTuningWork{}, try einsumTuningWork(options, 0));
}

test "einsum lowering work bounds each owned descriptor family directly" {
    const requests = [_]kernel_selection.EinsumSelectionRequest{
        .{ .dtype = .f32, .inputs = &.{
            .{ .indices = "mk", .dims = &.{ 5, 3 } },
            .{ .indices = "kn", .dims = &.{ 3, 7 } },
        }, .output_indices = "mn", .output_dims = &.{ 5, 7 } },
        .{ .dtype = .f32, .inputs = &.{
            .{ .indices = "bmk", .dims = &.{ 3, 5, 7 } },
            .{ .indices = "bkn", .dims = &.{ 3, 7, 9 } },
        }, .output_indices = "bmn", .output_dims = &.{ 3, 5, 9 } },
        .{ .dtype = .f32, .inputs = &.{
            .{ .indices = "mk", .dims = &.{ 5, 3 } },
            .{ .indices = "k", .dims = &.{3} },
        }, .output_indices = "m", .output_dims = &.{5} },
        .{ .dtype = .f32, .inputs = &.{
            .{ .indices = "m", .dims = &.{5} },
            .{ .indices = "n", .dims = &.{7} },
        }, .output_indices = "mn", .output_dims = &.{ 5, 7 } },
    };
    for (requests) |request| {
        const bytes = try testing.allocator.alloc(u8, @intCast(einsumDescriptorStorage()));
        defer testing.allocator.free(bytes);
        var buffer = std.heap.FixedBufferAllocator.init(bytes);
        const base = buffer.allocator();
        const vtable: std.mem.Allocator.VTable = .{
            .alloc = base.vtable.alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = std.mem.Allocator.noFree,
        };
        var selected = (try kernel_selection.selectOwnedEinsumCatalog(
            .{ .ptr = base.ptr, .vtable = &vtable },
            request,
        )).?;
        defer selected.deinit();
        try testing.expect(selected.descriptor.specialization != null);
        try testing.expect(buffer.end_index > 0);
        try testing.expect(buffer.end_index <= bytes.len);
    }
}

fn checkEinsumTuningAdmission(options: Options) !void {
    const allocator = testing.allocator;
    const revision = choir.product.revision;
    const module = try (EinsumCase{}).module();
    defer module.deinit();
    const root = module.choir_module;
    const before = try choir.bytecode.encodeModule(allocator, root);
    defer allocator.free(before);
    var baseline = options;
    if (baseline.matrix_product_tuning) |*reader| reader.records = reader.records[0..1];
    var family: kernel_library.tuning.FamilyTuningReader = undefined;
    if (baseline.family_tuning) |reader| {
        family = reader.*;
        family.table.records = family.table.records[0..1];
        baseline.family_tuning = &family;
    }
    const small = try einsumWork(.{ .operation = root, .state = &baseline });
    var allowance = revision.WorkVector.uniform(1 << 60);
    allowance.input_bytes = small.work.input_bytes;
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = allowance,
        .workspace = 1 << 30,
        .events = 4,
    }, &.{.{ .name = einsum_lowering_pass_name, .version = 1 }});
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
    try manager.addPass(einsumLoweringPassWithOptions(&options));
    try testing.expectEqual(
        .failure,
        manager.runWithAnalysisCache(root, module.context(), &cache, .{}),
    );
    try testing.expectEqual(.exhausted, ledger.view().outcome);
    try testing.expectEqual(@as(u64, 0), manager.stats.pass_runs);
    const after = try choir.bytecode.encodeModule(allocator, root);
    defer allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

test "einsum lowering work rejects enlarged tuning inputs before mutation" {
    const matrix: [257]EinsumTuningCase.Record = @splat(try EinsumTuningCase.matrixRecord());
    try checkEinsumTuningAdmission(.{
        .kernel_library = .enabled,
        .matrix_product_tuning = EinsumTuningCase.matrixReader(&matrix),
    });
    const records: [257]kernel_library.tuning.FamilyTuningRecord =
        @splat(try EinsumTuningCase.familyRecord("stale-target"));
    const reader = kernel_library.tuning.FamilyTuningReader.init(
        familyTuningTestCapabilities(),
        .{ .records = &records },
    );
    try checkEinsumTuningAdmission(.{ .kernel_library = .enabled, .family_tuning = &reader });
}

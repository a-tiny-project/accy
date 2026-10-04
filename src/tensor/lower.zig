const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const accy = @import("../root.zig");
const interpret = @import("interpret/root.zig");
const program_mod = @import("program.zig");
const trace = @import("trace/root.zig");
const unroll = @import("unroll.zig");
const types = @import("type/root.zig");

const ir = choir.ir;

pub const SemanticModule = accy.choir.SemanticModule;
pub const BackendPreparedJob = accy.preparation.BackendPreparedJob;
pub const BackendPreparationRunOptions = accy.preparation.BackendPreparationRunOptions;
pub const GeneratedScheduleKind = accy.preparation.GeneratedScheduleKind;
pub const GeneratedSchedule = accy.preparation.GeneratedSchedule;
pub const GeneratedKernelProgram = accy.preparation.GeneratedKernelProgram;
pub const GeneratedKernelSummary = accy.preparation.GeneratedKernelSummary;
pub const GeneratedKernelSummaries = accy.preparation.GeneratedKernelSummaries;
pub const ArtifactJob = accy.artifact.ArtifactJob;
pub const BackendHandle = gpu.BackendHandle;
pub const CompiledFragment = accy.executable.CompiledFragment;
pub const LoadedFragment = accy.executable.LoadedFragment;
pub const FragmentCompilerOptions = accy.executable.FragmentCompilerOptions;
pub const ArtifactKernelSource = accy.artifact.KernelSource;
pub const ArtifactKernelSummary = accy.artifact.KernelSummary;
pub const ArtifactKernelSummaries = accy.artifact.KernelSummaries;

pub const ScatterAddLowering = enum {
    expanded,
    semantic_kernel,
};

pub const SparseCrossEntropyLowering = enum {
    expanded,
    semantic_kernel,
};

pub const SemanticLoweringOptions = struct {
    context_limits: accy.choir.SemanticBuilder.ContextLimits = .standard,
    scatter_add: ScatterAddLowering = .expanded,
    sparse_cross_entropy: SparseCrossEntropyLowering = .expanded,

    pub fn eql(self: SemanticLoweringOptions, other: SemanticLoweringOptions) bool {
        return self.scatter_add == other.scatter_add and
            self.sparse_cross_entropy == other.sparse_cross_entropy and
            std.meta.eql(self.context_limits, other.context_limits);
    }
};

pub const FragmentCompilerCacheUpdate = accy.executable.FragmentCompilerCacheUpdate;
pub const FragmentCompilationRequest = accy.executable.FragmentCompilationRequest;

/// A caller keeps one of these per changing program so each recompile reuses the stages that did
/// not change. Each refresh lowers the program into a new semantic module inside a bounded compiler
/// job, sized by the context limits in the options. The compile that follows reuses a stage only
/// when an exact check admits the earlier stage record, the sealed result of one compile stage, for
/// the new request. A failed refresh keeps the previous compiled result and the previous loaded
/// fragment, the compiled and loaded program ready to launch. `currentPrepared` and
/// `currentFragment` return the result of the last successful refresh.
pub const FragmentCompilerCache = struct {
    allocator: std.mem.Allocator,
    cache: accy.executable.FragmentCompilerCache,

    pub fn init(allocator: std.mem.Allocator, handle: BackendHandle) FragmentCompilerCache {
        return .{
            .allocator = allocator,
            .cache = accy.executable.FragmentCompilerCache.init(allocator, handle),
        };
    }

    pub fn deinit(self: *FragmentCompilerCache) void {
        self.cache.deinit();
        self.* = undefined;
    }

    pub fn currentPrepared(
        self: *const FragmentCompilerCache,
    ) ?*const accy.preparation.pipeline.BackendPreparedModule {
        return self.cache.currentPrepared();
    }

    pub fn currentFragment(self: *const FragmentCompilerCache) ?*LoadedFragment {
        return self.cache.currentFragment();
    }

    pub fn refreshFromProgram(
        self: *FragmentCompilerCache,
        program: *const program_mod.Program,
        options: FragmentCompilerOptions,
        request: FragmentCompilationRequest,
        report: *accy.preparation.publication.PreparationReport,
        comptime configuration: choir.product.operation.Configuration,
    ) !FragmentCompilerCacheUpdate {
        const source = try toSemanticModuleWithOptions(
            self.allocator,
            program,
            semanticLoweringOptionsFromFragmentCompilerOptions(options),
        );
        return self.cache.refreshFromSemanticModule(
            source,
            options,
            request,
            report,
            configuration,
        );
    }
};

pub fn toSemanticModule(
    allocator: std.mem.Allocator,
    program: *const program_mod.Program,
) !*SemanticModule {
    return toSemanticModuleWithOptions(allocator, program, .{});
}

pub fn toSemanticModuleWithOptions(
    allocator: std.mem.Allocator,
    program: *const program_mod.Program,
    options: SemanticLoweringOptions,
) !*SemanticModule {
    if (program.containsScan()) {
        if (!programScansLowerAsIterate(program)) {
            var expanded = try unroll.apply(allocator, program);
            defer expanded.deinit();
            return toSemanticModuleWithOptions(allocator, &expanded, options);
        }
    }

    var builder = try accy.choir.SemanticBuilder.init(allocator, options.context_limits);
    errdefer builder.deinit();

    const choir_types = try allocator.alloc(ir.Type, program.valueCount());
    defer allocator.free(choir_types);
    for (program.values, 0..) |ty, index| {
        const shape = try types.extents(allocator, ty.dims);
        defer allocator.free(@constCast(shape));
        choir_types[index] = try builder.tensor(ty.dtype, shape);
    }

    const parameter_types = try allocator.alloc(ir.Type, program.parameters.len);
    defer allocator.free(parameter_types);
    for (program.parameters, 0..) |id, index| {
        parameter_types[index] = choir_types[id.index];
    }

    const result_types = try allocator.alloc(ir.Type, program.outputs.len);
    defer allocator.free(result_types);
    for (program.outputs, 0..) |id, index| {
        result_types[index] = choir_types[id.index];
    }

    var function = try builder.beginFunction(program.name, parameter_types, result_types);

    var scan_state = ScanLoweringState{};
    defer scan_state.deinit(allocator);

    try interpret.run(
        allocator,
        program,
        semantics(allocator, &function, choir_types, &scan_state, options),
    );

    return try builder.finish();
}

fn semanticLoweringOptionsFromPreparationOptions(
    options: BackendPreparationRunOptions,
) SemanticLoweringOptions {
    return .{
        .scatter_add = if (options.tensor.indexing.kernel_library == .enabled and
            options.tensor.indexing.scatter_add_schedule != null)
            .semantic_kernel
        else
            .expanded,
        .sparse_cross_entropy = if (options.tensor.loss.kernel_library == .enabled and
            options.tensor.loss.row_sparse_cross_entropy_schedule != null)
            .semantic_kernel
        else
            .expanded,
    };
}

fn semanticLoweringOptionsFromFragmentCompilerOptions(
    options: FragmentCompilerOptions,
) SemanticLoweringOptions {
    return .{
        .context_limits = options.semantic_context_limits,
        .scatter_add = if (options.kernel_call_registry != null and
            options.scatter_add_schedule != null)
            .semantic_kernel
        else
            .expanded,
        .sparse_cross_entropy = if (options.kernel_call_registry != null and
            options.row_sparse_cross_entropy_schedule != null)
            .semantic_kernel
        else
            .expanded,
    };
}

pub fn prepare(
    allocator: std.mem.Allocator,
    program: *const program_mod.Program,
) !BackendPreparedJob {
    return prepareWith(allocator, program, .{});
}

pub fn prepareWith(
    allocator: std.mem.Allocator,
    program: *const program_mod.Program,
    options: BackendPreparationRunOptions,
) !BackendPreparedJob {
    const module_value = try toSemanticModuleWithOptions(
        allocator,
        program,
        semanticLoweringOptionsFromPreparationOptions(options),
    );
    return accy.preparation.prepareBackendJobFromSemanticModule(allocator, module_value, options);
}

pub fn prepareFragment(
    allocator: std.mem.Allocator,
    handle: BackendHandle,
    program: *const program_mod.Program,
    options: FragmentCompilerOptions,
) !BackendPreparedJob {
    const module_value = try toSemanticModuleWithOptions(
        allocator,
        program,
        semanticLoweringOptionsFromFragmentCompilerOptions(options),
    );
    return accy.executable.prepareFragmentFromSemanticModule(
        allocator,
        handle,
        module_value,
        options,
    );
}

pub fn compileFragmentFromPreparedJob(
    allocator: std.mem.Allocator,
    handle: BackendHandle,
    prepared: *BackendPreparedJob,
    options: FragmentCompilerOptions,
) !*CompiledFragment {
    return try accy.executable.compileFragmentFromPreparedJob(
        allocator,
        handle,
        prepared,
        options,
    );
}

pub fn createArtifactJobFromPreparedJob(
    allocator: std.mem.Allocator,
    handle: BackendHandle,
    prepared: *BackendPreparedJob,
    options: FragmentCompilerOptions,
) !*ArtifactJob {
    return accy.executable.createArtifactJobFromPreparedJob(
        allocator,
        handle,
        prepared,
        options,
    );
}

pub fn compileFragmentFromArtifactJob(
    allocator: std.mem.Allocator,
    artifact_module: *ArtifactJob,
) !*CompiledFragment {
    return try accy.executable.compileFragmentFromArtifactJob(allocator, artifact_module);
}

pub fn createArtifactJob(
    allocator: std.mem.Allocator,
    handle: BackendHandle,
    program: *const program_mod.Program,
    options: FragmentCompilerOptions,
) !*ArtifactJob {
    var prepared = try prepareFragment(allocator, handle, program, options);
    defer prepared.deinit();
    return try createArtifactJobFromPreparedJob(allocator, handle, &prepared, options);
}

pub fn compileFragment(
    allocator: std.mem.Allocator,
    handle: BackendHandle,
    program: *const program_mod.Program,
    options: FragmentCompilerOptions,
) !*CompiledFragment {
    if (try compileHostLoopScanFragment(allocator, handle, program, options)) |fragment| {
        return fragment;
    }
    const module_value = try toSemanticModuleWithOptions(
        allocator,
        program,
        semanticLoweringOptionsFromFragmentCompilerOptions(options),
    );
    return try accy.executable.compileFragmentFromSemanticModule(
        allocator,
        handle,
        module_value,
        options,
    );
}

fn compileHostLoopScanFragment(
    allocator: std.mem.Allocator,
    handle: BackendHandle,
    program: *const program_mod.Program,
    options: FragmentCompilerOptions,
) !?*CompiledFragment {
    const scan = hostLoopScanCandidate(program) orelse return null;

    var body_program = try hostLoopScanBodyProgram(allocator, program.name, scan);
    defer body_program.deinit();

    const module_value = try toSemanticModuleWithOptions(
        allocator,
        &body_program,
        semanticLoweringOptionsFromFragmentCompilerOptions(options),
    );
    var prepared = try accy.executable.prepareFragmentFromSemanticModule(
        allocator,
        handle,
        module_value,
        options,
    );
    defer prepared.deinit();

    try accy.executable.fragment.recordBackendPreparationRun(options.instrumentation, prepared.run);

    const artifact_module = try createArtifactJobFromPreparedJob(
        allocator,
        handle,
        &prepared,
        options,
    );
    defer artifact_module.deinit();

    const launch_plan = try hostLoopScanLaunchPlan(
        allocator,
        artifact_module.artifactPlan(),
        @intCast(scan.length),
    );

    return try accy.executable.compileFragmentFromArtifactJobWithLaunchPlan(
        allocator,
        artifact_module,
        launch_plan,
    );
}

fn hostLoopScanCandidate(program: *const program_mod.Program) ?program_mod.Scan {
    if (program.outputs.len != 1) return null;

    var scan_op: ?program_mod.Operation = null;
    for (program.operations) |op| {
        switch (op.kind) {
            .scan => {
                if (scan_op != null) return null;
                scan_op = op;
            },
            .projection => return null,
            else => {},
        }
    }

    const op = scan_op orelse return null;
    if (program.outputs[0].index != op.id.index) return null;
    const scan = op.kind.scan;
    if (scan.length <= 0) return null;
    if (scan.inits.len != 1 or scan.body.outputs.len != 1) return null;
    if (scanLowersAsIterate(program, scan)) return null;
    if (!hostLoopScanBodySupported(scan)) return null;
    return scan;
}

fn hostLoopScanBodySupported(scan: program_mod.Scan) bool {
    var has_complex_body = false;
    for (scan.body.operations) |op| {
        switch (op.kind) {
            .parameter,
            .constant,
            .unary,
            .binary,
            .iota,
            .broadcast,
            .broadcast_in_dim,
            .reshape,
            .transpose,
            .compare,
            .select,
            => {},
            .reduce,
            .dot_general,
            => has_complex_body = true,
            else => return false,
        }
    }
    return has_complex_body;
}

fn hostLoopScanBodyProgram(
    allocator: std.mem.Allocator,
    name: []const u8,
    scan: program_mod.Scan,
) !program_mod.Program {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();
    const body = try program_mod.cloneSubgraph(arena_allocator, scan.body);
    const body_name = try std.fmt.allocPrint(arena_allocator, "{s}_scan_body", .{name});
    const outputs = try arena_allocator.alloc(program_mod.Id, 1);
    outputs[0] = if (@mod(scan.length, 2) == 0) body.parameters[0] else body.outputs[0];

    return .{
        .arena = arena,
        .name = body_name,
        .values = body.values,
        .operations = body.operations,
        .parameters = body.parameters,
        .outputs = outputs,
    };
}

fn hostLoopScanLaunchPlan(
    allocator: std.mem.Allocator,
    artifact_plan: *const accy.artifact.BackendArtifactPlan,
    trip_count: u64,
) !accy.executable.OwnedLaunchGraphPlan {
    if (artifact_plan.input_slot_ids.len != 1) return error.UnsupportedOperation;
    if (artifact_plan.output_slot_ids.len != 1) return error.UnsupportedOperation;
    if (artifact_plan.kernels.items.len == 0) return error.UnsupportedOperation;

    var launch_plan = try accy.executable.createDataflowLaunchGraphPlan(
        allocator,
        artifact_plan,
        .{},
    );
    errdefer launch_plan.deinit();

    const carries = allocator.alloc(
        accy.executable.LaunchGraphLoopCarry,
        1,
    ) catch return error.OutOfMemory;
    errdefer allocator.free(carries);

    const initial_slot_id = artifact_plan.input_slot_ids[0];
    const output_slot_id = artifact_plan.kernels.items[
        artifact_plan.kernels.items.len -
            1
    ].output_slot_id;
    const final_slot_id = artifact_plan.output_slot_ids[0];
    carries[0] = .{
        .initial_slot_id = initial_slot_id,
        .input_slot_id = initial_slot_id,
        .output_slot_id = output_slot_id,
        .final_slot_id = final_slot_id,
    };
    if (accy.executable.launchGraphLoopCarryFinalSlot(carries[0], trip_count) != final_slot_id) {
        return error.InvalidArtifact;
    }

    const loops = allocator.alloc(
        accy.executable.LaunchGraphLoop,
        1,
    ) catch return error.OutOfMemory;
    errdefer allocator.free(loops);
    loops[0] = .{
        .first_node_index = 0,
        .node_count = launch_plan.nodes.len,
        .trip_count = trip_count,
        .carries = carries,
    };

    launch_plan.loops = loops;
    return launch_plan;
}

pub fn module(allocator: std.mem.Allocator) Module {
    return .{ .allocator = allocator };
}

pub const Module = struct {
    allocator: std.mem.Allocator,

    pub fn attach(self: @This(), next: anytype) interpret.Layer(trace.Value, @TypeOf(
        next,
    ), ModuleLower) {
        return interpret.layer(trace.Value, next, ModuleLower{ .allocator = self.allocator });
    }
};

pub const ModuleLower = struct {
    allocator: std.mem.Allocator,
    options: SemanticLoweringOptions = .{},

    pub const Result = *SemanticModule;

    pub fn finish(self: *@This(), ctx: anytype, outputs: []const trace.Value) !Result {
        var graph = try ctx.default(outputs);
        defer graph.deinit();

        return toSemanticModuleWithOptions(self.allocator, &graph, self.options);
    }
};

pub fn semantics(
    allocator: std.mem.Allocator,
    function: *accy.choir.semantic.FunctionBuilder,
    choir_types: []const ir.Type,
    scan_state: *ScanLoweringState,
    options: SemanticLoweringOptions,
) Semantics {
    return .{
        .allocator = allocator,
        .function = function,
        .choir_types = choir_types,
        .scan_state = scan_state,
        .options = options,
    };
}

pub const ScanLoweringState = struct {
    results: std.AutoHashMapUnmanaged(u32, []const *ir.Value) = .empty,

    fn deinit(self: *ScanLoweringState, allocator: std.mem.Allocator) void {
        var iter = self.results.valueIterator();
        while (iter.next()) |values| allocator.free(values.*);
        self.results.deinit(allocator);
        self.* = undefined;
    }
};

pub const Semantics = struct {
    allocator: std.mem.Allocator,
    function: *accy.choir.semantic.FunctionBuilder,
    choir_types: []const ir.Type,
    scan_state: *ScanLoweringState,
    options: SemanticLoweringOptions,

    pub const Value = *ir.Value;
    pub const Result = void;

    pub fn operation(self: *@This(), step: *interpret.Step(Value)) !Value {
        switch (step.op.kind) {
            .scan => |scan| return self.lowerScan(step.op, scan, step.values),
            .projection => |projection| return self.scan_state.results.get(
                projection.source.index,
            ).?[projection.index],
            else => {},
        }
        var buffer: [program_mod.max_operation_operands]Value = undefined;
        return self.bind(step.op, interpret.arguments(Value, step.op, step.values, &buffer));
    }

    pub fn bind(self: *@This(), op: *const program_mod.Operation, args: []const Value) !Value {
        return lowerOperation(
            self.allocator,
            self.function,
            self.choir_types[op.id.index],
            op,
            args,
            self.options,
        );
    }

    fn lowerScan(
        self: *@This(),
        op: *const program_mod.Operation,
        scan: program_mod.Scan,
        values: []const Value,
    ) !Value {
        var inits: [program_mod.max_scan_carries]Value = undefined;
        for (scan.inits, 0..) |init, index| inits[index] = values[init.index];

        var iterate = try self.function.beginIterate(inits[0..scan.inits.len], scan.length);
        errdefer iterate.body.terminated = true;

        const body_values = try self.allocator.alloc(Value, scan.body.values.len);
        defer self.allocator.free(body_values);

        for (scan.body.operations) |*body_op| {
            body_values[body_op.id.index] = switch (body_op.kind) {
                .parameter => |parameter| iterate.carry(parameter.index),
                .scan, .projection => return error.ScanRequiresExpansion,
                else => blk: {
                    var buffer: [program_mod.max_operation_operands]Value = undefined;
                    const args = interpret.arguments(Value, body_op, body_values, &buffer);
                    const result_type = try semanticType(
                        self.allocator,
                        iterate.body.ctx,
                        body_op.result,
                    );
                    break :blk try lowerOperation(
                        self.allocator,
                        iterate.inner(),
                        result_type,
                        body_op,
                        args,
                        self.options,
                    );
                },
            };
        }

        const output_count = scan.body.outputs.len;
        const yielded = try self.allocator.alloc(Value, output_count);
        defer self.allocator.free(yielded);
        for (scan.body.outputs, 0..) |id, index| yielded[index] = body_values[id.index];

        const predicate = try truePredicate(
            self.allocator,
            iterate.inner(),
            scan.body.typeOf(scan.body.outputs[0]),
        );
        try iterate.yield_(predicate, yielded);

        const results = try self.allocator.alloc(Value, output_count);
        errdefer self.allocator.free(results);
        for (results, 0..) |*result, index| result.* = iterate.result(index);
        try self.scan_state.results.put(self.allocator, op.id.index, results);
        return results[0];
    }

    pub fn finish(self: *@This(), outputs: []const Value) !Result {
        try self.function.return_(outputs);
        try self.function.finish();
    }
};

fn lowerOperation(
    allocator: std.mem.Allocator,
    function: *accy.choir.semantic.FunctionBuilder,
    result_type: ir.Type,
    op: *const program_mod.Operation,
    args: []const *ir.Value,
    options: SemanticLoweringOptions,
) !*ir.Value {
    return switch (op.kind) {
        .scan, .projection => error.ScanRequiresExpansion,
        .parameter => |parameter| function.parameter(parameter.index),
        .constant => |constant| function.constant(result_type, constant.payload),
        .unary => |unary| lowerUnary(function, unary.op, args[0]),
        .binary => |binary| lowerBinary(function, binary.op, args[0], args[1]),
        .iota => |iota| function.iota(result_type, @intCast(iota.axis)),
        .broadcast => |broadcast| function.broadcast(args[0], result_type, broadcast.sizes),
        .broadcast_in_dim => |broadcast| blk: {
            const result_shape = try types.extents(allocator, op.result.dims);
            defer allocator.free(@constCast(result_shape));
            break :blk function.broadcastInDim(
                args[0],
                result_type,
                result_shape,
                broadcast.broadcast_dims,
            );
        },
        .reshape => |reshape| function.reshape(args[0], result_type, reshape.new_shape),
        .transpose => |transpose| function.transpose(args[0], result_type, transpose.permutation),
        .reduce => |reduce| function.reduce(
            args[0],
            args[1],
            result_type,
            reduce.reducer.name(),
            reduce.dimensions,
        ),
        .gather => |gather| function.gather(args[0], args[1], result_type, gather.axis),
        .scatter_add => |scatter_add| lowerScatterAdd(
            allocator,
            function,
            result_type,
            op,
            scatter_add,
            args[0],
            args[1],
            args[2],
            options,
        ),
        .sparse_cross_entropy => |sparse_cross_entropy| lowerSparseCrossEntropy(
            allocator,
            function,
            result_type,
            op,
            sparse_cross_entropy,
            args[0],
            args[1],
            options,
        ),
        .compare => |compare| function.compare(
            args[0],
            args[1],
            result_type,
            switch (compare.direction) {
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
                .eq => .eq,
                .ne => .ne,
            },
        ),
        .select => function.select(args[0], args[1], args[2]),
        .custom_call => |custom| blk: {
            const effects = @as(
                [program_mod.max_custom_call_operands]accy.choir.semantic.KernelOperandEffect,
                @splat(.read),
            );
            const aliases = [_]?usize{null};
            const call = try function.kernelCall(args, &.{result_type}, .{
                .target = custom.target,
                .version = custom.version,
                .operand_effects = effects[0..args.len],
                .result_aliases = aliases[0..],
            });
            break :blk call.getFirstResult();
        },
        .dot_general => |dot| function.dotGeneral(
            args[0],
            args[1],
            result_type,
            dot.lhs_contract,
            dot.rhs_contract,
            dot.lhs_batch,
            dot.rhs_batch,
        ),
    };
}

fn lowerScatterAdd(
    allocator: std.mem.Allocator,
    function: *accy.choir.semantic.FunctionBuilder,
    result_type: ir.Type,
    op: *const program_mod.Operation,
    scatter_add: program_mod.ScatterAdd,
    input: *ir.Value,
    indices: *ir.Value,
    updates: *ir.Value,
    options: SemanticLoweringOptions,
) !*ir.Value {
    if (options.scatter_add == .semantic_kernel and
        try scatterAddSemanticKernelEligible(allocator, op, scatter_add, indices, updates))
    {
        return function.scatterAdd(input, indices, updates, result_type, scatter_add.axis);
    }
    return lowerScatterAddExpanded(
        allocator,
        function,
        result_type,
        op,
        scatter_add,
        input,
        indices,
        updates,
    );
}

fn lowerScatterAddExpanded(
    allocator: std.mem.Allocator,
    function: *accy.choir.semantic.FunctionBuilder,
    result_type: ir.Type,
    op: *const program_mod.Operation,
    scatter_add: program_mod.ScatterAdd,
    input: *ir.Value,
    indices: *ir.Value,
    updates: *ir.Value,
) !*ir.Value {
    if (scatter_add.axis < 0) return error.AxisOutOfRange;
    const axis = std.math.cast(usize, scatter_add.axis) orelse return error.AxisOutOfRange;
    if (axis >= op.result.rank()) return error.AxisOutOfRange;
    const input_shape = try types.extents(allocator, op.result.dims);
    defer allocator.free(@constCast(input_shape));
    const indices_type = try accy.choir.dialect.decodeTensorType(allocator, indices.type);
    defer allocator.free(@constCast(indices_type.dims));
    const updates_type = try accy.choir.dialect.decodeTensorType(allocator, updates.type);
    defer allocator.free(@constCast(updates_type.dims));
    const index_rank = indices_type.dims.len;
    if (updates_type.dims.len != op.result.rank() - 1 + index_rank) return error.RankMismatch;

    const expanded_shape = try allocator.alloc(i64, op.result.rank() + index_rank);
    var expanded_out: usize = 0;
    for (input_shape[0..axis]) |dim| {
        expanded_shape[expanded_out] = dim;
        expanded_out += 1;
    }
    expanded_shape[expanded_out] = input_shape[axis];
    expanded_out += 1;
    for (indices_type.dims) |dim| {
        expanded_shape[expanded_out] = dim;
        expanded_out += 1;
    }
    for (input_shape[axis + 1 ..]) |dim| {
        expanded_shape[expanded_out] = dim;
        expanded_out += 1;
    }
    defer allocator.free(expanded_shape);

    const expanded_data_type = try accy.choir.dialect.accyTensorType(
        function.ctx,
        op.result.dtype,
        expanded_shape,
    );
    const expanded_index_type = try accy.choir.dialect.accyTensorType(
        function.ctx,
        .i32,
        expanded_shape,
    );
    const expanded_mask_type = try accy.choir.dialect.accyTensorType(
        function.ctx,
        .i1,
        expanded_shape,
    );

    const source_positions = try function.iota(expanded_index_type, @intCast(axis));
    const indices_broadcast_dims = try allocator.alloc(i64, index_rank);
    defer allocator.free(indices_broadcast_dims);
    for (indices_broadcast_dims, 0..) |*slot, index| {
        slot.* = @intCast(axis + 1 + index);
    }
    const broadcasted_indices = try function.broadcastInDim(
        indices,
        expanded_index_type,
        expanded_shape,
        indices_broadcast_dims,
    );

    const update_mapping = try allocator.alloc(i64, updates_type.dims.len);
    defer allocator.free(update_mapping);
    for (update_mapping, 0..) |*slot, index| {
        slot.* = if (index < axis)
            @intCast(index)
        else if (index < axis + index_rank)
            @intCast(index + 1)
        else
            @intCast(index + 1);
    }
    const broadcasted_updates = try function.broadcastInDim(
        updates,
        expanded_data_type,
        expanded_shape,
        update_mapping,
    );
    const mask = try function.compare(
        source_positions,
        broadcasted_indices,
        expanded_mask_type,
        .eq,
    );
    const zero_scalar_type = try accy.choir.dialect.accyTensorType(
        function.ctx,
        op.result.dtype,
        &.{},
    );
    var zero_bytes: [32]u8 = @as([32]u8, @splat(0));
    const zero_scalar = try function.constant(
        zero_scalar_type,
        zero_bytes[0..op.result.dtype.sizeOf()],
    );
    const zero_updates = try function.broadcastInDim(
        zero_scalar,
        expanded_data_type,
        expanded_shape,
        &.{},
    );
    const selected = try function.select(mask, broadcasted_updates, zero_updates);
    const reduce_axes = try allocator.alloc(i64, index_rank);
    defer allocator.free(reduce_axes);
    for (reduce_axes, 0..) |*slot, index| {
        slot.* = @intCast(axis + 1 + index);
    }
    const reduced = if (index_rank == 0)
        selected
    else
        try function.reduce(selected, zero_scalar, result_type, "sum", reduce_axes);
    return function.add(input, reduced);
}

fn lowerSparseCrossEntropy(
    allocator: std.mem.Allocator,
    function: *accy.choir.semantic.FunctionBuilder,
    result_type: ir.Type,
    op: *const program_mod.Operation,
    sparse_cross_entropy: program_mod.SparseCrossEntropy,
    logits: *ir.Value,
    targets: *ir.Value,
    options: SemanticLoweringOptions,
) !*ir.Value {
    if (options.sparse_cross_entropy == .semantic_kernel and
        try sparseCrossEntropySemanticKernelEligible(
            allocator,
            op,
            sparse_cross_entropy,
            logits,
            targets,
        ))
    {
        return function.sparseCrossEntropy(logits, targets, result_type);
    }
    return lowerSparseCrossEntropyExpanded(
        allocator,
        function,
        result_type,
        sparse_cross_entropy,
        logits,
        targets,
    );
}

fn lowerSparseCrossEntropyExpanded(
    allocator: std.mem.Allocator,
    function: *accy.choir.semantic.FunctionBuilder,
    result_type: ir.Type,
    sparse_cross_entropy: program_mod.SparseCrossEntropy,
    logits: *ir.Value,
    targets: *ir.Value,
) !*ir.Value {
    if (sparse_cross_entropy.axis < 0) return error.AxisOutOfRange;
    const axis = std.math.cast(usize, sparse_cross_entropy.axis) orelse return error.AxisOutOfRange;
    const logits_type = try accy.choir.dialect.decodeTensorType(allocator, logits.type);
    defer allocator.free(@constCast(logits_type.dims));
    if (axis >= logits_type.dims.len) return error.AxisOutOfRange;
    const class_axes = [_]i64{@intCast(axis)};

    const logits_index_type = try accy.choir.dialect.accyTensorType(
        function.ctx,
        .i32,
        logits_type.dims,
    );
    const logits_mask_type = try accy.choir.dialect.accyTensorType(
        function.ctx,
        .i1,
        logits_type.dims,
    );
    const logits_data_type = logits.type;

    const back_mapping = try allocator.alloc(i64, logits_type.dims.len - 1);
    defer allocator.free(back_mapping);
    var mapping_out: usize = 0;
    for (0..logits_type.dims.len) |position| {
        if (position == axis) continue;
        back_mapping[mapping_out] = @intCast(position);
        mapping_out += 1;
    }

    const max_init = try lowerFloatLowestConstant(function, logits_type.dtype);
    const row_max = try function.reduce(logits, max_init, result_type, "max", class_axes[0..]);
    const row_max_full = try function.broadcastInDim(
        row_max,
        logits_data_type,
        logits_type.dims,
        back_mapping,
    );
    const shifted = try function.sub(logits, row_max_full);
    const exponentials = try function.exp(shifted);

    const zero_scalar_type = try accy.choir.dialect.accyTensorType(
        function.ctx,
        logits_type.dtype,
        &.{},
    );
    var zero_bytes: [32]u8 = @as([32]u8, @splat(0));
    const zero_scalar = try function.constant(
        zero_scalar_type,
        zero_bytes[0..logits_type.dtype.sizeOf()],
    );
    const denominator = try function.reduce(
        exponentials,
        zero_scalar,
        result_type,
        "sum",
        class_axes[0..],
    );
    const log_denominator = try function.log(denominator);

    const class_positions = try function.iota(logits_index_type, @intCast(axis));
    const target_positions = try function.broadcastInDim(
        targets,
        logits_index_type,
        logits_type.dims,
        back_mapping,
    );
    const mask = try function.compare(class_positions, target_positions, logits_mask_type, .eq);
    const zero_full = try function.broadcastInDim(
        zero_scalar,
        logits_data_type,
        logits_type.dims,
        &.{},
    );
    const selected = try function.select(mask, shifted, zero_full);
    const target_shifted = try function.reduce(
        selected,
        zero_scalar,
        result_type,
        "sum",
        class_axes[0..],
    );
    return function.sub(log_denominator, target_shifted);
}

fn lowerFloatLowestConstant(
    function: *accy.choir.semantic.FunctionBuilder,
    dtype: gpu_abi.DType,
) !*ir.Value {
    const scalar_type = try accy.choir.dialect.accyTensorType(function.ctx, dtype, &.{});
    return switch (dtype) {
        .f16 => blk: {
            const value: f16 = -std.math.floatMax(f16);
            break :blk function.constant(scalar_type, std.mem.asBytes(&value));
        },
        .bf16 => blk: {
            const value = gpu_abi.DType.bf16.ZigType().fromF32(-std.math.floatMax(f32));
            break :blk function.constant(scalar_type, std.mem.asBytes(&value));
        },
        .f32 => blk: {
            const value: f32 = -std.math.floatMax(f32);
            break :blk function.constant(scalar_type, std.mem.asBytes(&value));
        },
        .f64 => blk: {
            const value: f64 = -std.math.floatMax(f64);
            break :blk function.constant(scalar_type, std.mem.asBytes(&value));
        },
        else => error.NonFloatDType,
    };
}

fn sparseCrossEntropySemanticKernelEligible(
    allocator: std.mem.Allocator,
    op: *const program_mod.Operation,
    sparse_cross_entropy: program_mod.SparseCrossEntropy,
    logits: *ir.Value,
    targets: *ir.Value,
) !bool {
    if (!accy.kernel.library.loss.rowSparseCrossEntropyDTypeSupported(op.result.dtype)) {
        return false;
    }

    const logits_type = try accy.choir.dialect.decodeTensorType(allocator, logits.type);
    defer allocator.free(@constCast(logits_type.dims));
    const targets_type = try accy.choir.dialect.decodeTensorType(allocator, targets.type);
    defer allocator.free(@constCast(targets_type.dims));
    if (logits_type.dims.len != 2 or targets_type.dims.len != 1) return false;
    if (sparse_cross_entropy.axis != 1) return false;
    if (targets_type.dtype != .i32) return false;
    if (logits_type.dims[0] <= 0 or logits_type.dims[1] <= 0) return false;
    if (targets_type.dims[0] != logits_type.dims[0]) return false;
    return true;
}

fn scatterAddSemanticKernelEligible(
    allocator: std.mem.Allocator,
    op: *const program_mod.Operation,
    scatter_add: program_mod.ScatterAdd,
    indices: *ir.Value,
    updates: *ir.Value,
) !bool {
    if (scatter_add.axis < 0) return false;
    const axis = std.math.cast(usize, scatter_add.axis) orelse return false;
    if (axis >= op.result.rank()) return false;
    if (!accy.kernel.library.indexing.scatterAddDTypeSupported(op.result.dtype)) return false;

    const input_shape = try types.extents(allocator, op.result.dims);
    defer allocator.free(@constCast(input_shape));
    for (input_shape) |dim| {
        if (dim <= 0) return false;
    }

    const indices_type = try accy.choir.dialect.decodeTensorType(allocator, indices.type);
    defer allocator.free(@constCast(indices_type.dims));
    const updates_type = try accy.choir.dialect.decodeTensorType(allocator, updates.type);
    defer allocator.free(@constCast(updates_type.dims));
    if (indices_type.dtype != .i32) return false;
    if (updates_type.dtype != op.result.dtype) return false;
    if (indices_type.dims.len != 1) return false;
    if (updates_type.dims.len != op.result.rank()) return false;
    if (indices_type.dims[0] <= 0) return false;
    for (updates_type.dims) |dim| {
        if (dim <= 0) return false;
    }

    if (!std.mem.eql(i64, updates_type.dims[0..axis], input_shape[0..axis])) return false;
    if (updates_type.dims[axis] != indices_type.dims[0]) return false;
    if (!std.mem.eql(i64, updates_type.dims[axis + 1 ..], input_shape[axis + 1 ..])) return false;
    return true;
}

fn semanticType(allocator: std.mem.Allocator, ctx: *ir.Context, ty: program_mod.Type) !ir.Type {
    const shape = try types.extents(allocator, ty.dims);
    defer allocator.free(@constCast(shape));
    return accy.choir.dialect.accyTensorType(ctx, ty.dtype, shape);
}

fn truePredicate(
    allocator: std.mem.Allocator,
    function: *accy.choir.semantic.FunctionBuilder,
    carry_ty: program_mod.Type,
) !*ir.Value {
    const scalar_ty = try accy.choir.dialect.accyTensorType(function.ctx, .i1, &.{});
    var payload = [_]u8{1};
    const scalar = try function.constant(scalar_ty, payload[0..]);
    if (carry_ty.rank() == 0) return scalar;
    const shape = try types.extents(allocator, carry_ty.dims);
    defer allocator.free(@constCast(shape));
    const pred_ty = try accy.choir.dialect.accyTensorType(function.ctx, .i1, shape);
    return function.broadcast(scalar, pred_ty, shape);
}

fn programScansLowerAsIterate(program: *const program_mod.Program) bool {
    for (program.operations) |op| {
        switch (op.kind) {
            .scan => |scan| if (!scanLowersAsIterate(program, scan)) return false,
            else => {},
        }
    }
    return true;
}

fn scanLowersAsIterate(source: anytype, scan: program_mod.Scan) bool {
    if (scan.length <= 0) return false;
    if (scan.inits.len == 0 or scan.inits.len > 8) return false;
    const domain = scanElementDomain(source, scan) orelse return false;
    if (scan.body.outputs.len != scan.inits.len) return false;
    for (scan.body.outputs, scan.inits) |output, init| {
        const output_ty = scan.body.typeOf(output);
        const init_ty = source.typeOf(init);
        if (!output_ty.eql(init_ty)) return false;
    }
    for (scan.body.operations) |op| {
        if (!bodyOperationLowersAsIterate(scan.body, op, domain)) return false;
    }
    return true;
}

fn scanElementDomain(source: anytype, scan: program_mod.Scan) ?usize {
    var domain: ?usize = null;
    for (scan.inits) |init| {
        const count = typeElementCount(source.typeOf(init)) orelse return null;
        if (count == 1) continue;
        if (domain) |existing| {
            if (count != existing) return null;
        } else {
            domain = count;
        }
    }
    return domain orelse 1;
}

fn typeElementCount(ty: program_mod.Type) ?usize {
    var count: usize = 1;
    for (ty.dims) |dim| {
        if (dim.extent <= 0) return null;
        count = std.math.mul(usize, count, @intCast(dim.extent)) catch return null;
    }
    return count;
}

fn bodyOperationLowersAsIterate(
    body: *const program_mod.Subgraph,
    op: program_mod.Operation,
    domain: usize,
) bool {
    if (!domainCompatible(body.typeOf(op.id), domain)) return false;
    return switch (op.kind) {
        .parameter => true,
        .constant => |constant| constantLowersAsSplat(body.typeOf(op.id), constant.payload),
        .unary, .binary, .compare, .select => true,
        .reshape => |reshape| sameElementCount(body.typeOf(reshape.input), body.typeOf(op.id)),
        .broadcast => |broadcast| constantProducer(body, broadcast.input),
        .broadcast_in_dim => |broadcast| constantProducer(body, broadcast.input),
        .custom_call => |custom| customCallLowersAsIterate(body, op, custom, domain),
        else => false,
    };
}

fn domainCompatible(ty: program_mod.Type, domain: usize) bool {
    const count = typeElementCount(ty) orelse return false;
    return count == 1 or count == domain;
}

fn sameElementCount(lhs: program_mod.Type, rhs: program_mod.Type) bool {
    const lhs_count = typeElementCount(lhs) orelse return false;
    const rhs_count = typeElementCount(rhs) orelse return false;
    return lhs_count == rhs_count;
}

fn customCallLowersAsIterate(
    body: *const program_mod.Subgraph,
    op: program_mod.Operation,
    custom: program_mod.CustomCall,
    domain: usize,
) bool {
    const spec = parsePhiloxKeyCounterUniformTarget(custom.target) orelse return false;
    if (custom.version != accy.kernel.library.random.philox_key_counter_uniform_family_version) {
        return false;
    }
    if (custom.operands.len != 2) return false;
    if (body.typeOf(custom.operands[0]).rank() != 0 or
        body.typeOf(custom.operands[0]).dtype != .key) return false;
    if (body.typeOf(custom.operands[1]).rank() != 0 or
        body.typeOf(custom.operands[1]).dtype != .i32) return false;
    if (op.result.dtype != spec.dtype) return false;
    return (typeElementCount(op.result) orelse return false) == domain;
}

const PhiloxKeyCounterUniformTarget = struct {
    rounds: u32,
    dtype: gpu_abi.DType,
};

fn parsePhiloxKeyCounterUniformTarget(target: []const u8) ?PhiloxKeyCounterUniformTarget {
    const prefix = "accy.kernel.random.philox_key_counter_uniform_family_";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];
    const rounds_end = std.mem.indexOf(u8, rest, "r_") orelse return null;
    const rounds = std.fmt.parseInt(u32, rest[0..rounds_end], 10) catch return null;
    const after_rounds = rest[rounds_end + 2 ..];
    const dtype_start = std.mem.lastIndexOfScalar(u8, after_rounds, '_') orelse return null;
    const dtype = gpu_abi.DType.fromName(after_rounds[dtype_start + 1 ..]) orelse return null;
    if (!accy.kernel.library.random.randomDTypeSupported(dtype)) return null;
    return .{ .rounds = rounds, .dtype = dtype };
}

fn constantProducer(body: *const program_mod.Subgraph, id: program_mod.Id) bool {
    const op = body.operation(id);
    return switch (op.kind) {
        .constant => |constant| constantLowersAsSplat(op.result, constant.payload),
        else => false,
    };
}

fn constantLowersAsSplat(ty: program_mod.Type, payload: []const u8) bool {
    return switch (ty.dtype) {
        .f32, .i32 => blk: {
            if (payload.len < 4 or payload.len % 4 != 0) break :blk false;
            var first: u32 = undefined;
            @memcpy(std.mem.asBytes(&first), payload[0..4]);
            var offset: usize = 4;
            while (offset < payload.len) : (offset += 4) {
                var value: u32 = undefined;
                @memcpy(std.mem.asBytes(&value), payload[offset..][0..4]);
                if (value != first) break :blk false;
            }
            break :blk true;
        },
        .i1 => blk: {
            if (payload.len == 0) break :blk false;
            const first = payload[0];
            for (payload[1..]) |value| {
                if (value != first) break :blk false;
            }
            break :blk true;
        },
        .key => payload.len == @sizeOf(gpu_abi.Key),
        else => false,
    };
}

fn lowerUnary(
    function: *accy.choir.semantic.FunctionBuilder,
    op: program_mod.Unary,
    input: *ir.Value,
) !*ir.Value {
    return switch (op) {
        .neg => function.neg(input),
        .abs => function.abs(input),
        .exp => function.exp(input),
        .log => function.log(input),
        .sqrt => function.sqrt(input),
        .tanh => function.tanh(input),
        .sin => function.sin(input),
        .cos => function.cos(input),
        .tan => function.tan(input),
    };
}

fn lowerBinary(
    function: *accy.choir.semantic.FunctionBuilder,
    op: program_mod.Binary,
    lhs: *ir.Value,
    rhs: *ir.Value,
) !*ir.Value {
    return switch (op) {
        .add => function.add(lhs, rhs),
        .sub => function.sub(lhs, rhs),
        .mul => function.mul(lhs, rhs),
        .div => function.div(lhs, rhs),
        .max => function.max(lhs, rhs),
        .min => function.min(lhs, rhs),
        .pow => function.pow(lhs, rhs),
    };
}

test "tensor lowering produces verified semantic Choir" {
    var builder = try accy.tensor.Builder.init(std.testing.allocator, "lower_dense");
    defer builder.deinit();

    const x = try builder.input(.f32, .{ .m = 4, .k = 8 });
    const w = try builder.input(.f32, .{ .k = 8, .n = 3 });
    const b = try builder.input(.f32, .{ .n = 3 });
    const out = try (try (try x.contract(w, .k)).add(b)).tanh();
    var program = try builder.finish(&.{out});
    defer program.deinit();

    const lowered = try toSemanticModule(std.testing.allocator, &program);
    defer lowered.deinit();

    try lowered.verify();
}

test "tensor lowering expands scatter add through semantic accumulation" {
    var builder = try accy.tensor.Builder.init(std.testing.allocator, "lower_indexing");
    defer builder.deinit();

    const table = try builder.input(.f32, .{ .vocab = 16, .channel = 4 });
    const ids = try builder.input(.i32, .{ .token = 3 });
    const gathered = try table.gather(ids, .vocab);
    const zero_table = try builder.full(.f32, .{ .vocab = 16, .channel = 4 }, 0.0);
    const out = try zero_table.scatterAdd(ids, gathered, .vocab);
    var program = try builder.finish(&.{out});
    defer program.deinit();

    const lowered = try toSemanticModule(std.testing.allocator, &program);
    defer lowered.deinit();

    try lowered.verify();
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.GatherOp.operation_name,
        ),
    );
    try std.testing.expect(ir.inspection.countOperationsNamed(
        lowered.choir_module,
        accy.choir.dialect.AccyDialect.ReduceOp.operation_name,
    ) >= 1);
}

test "tensor lowering expands scatter add with shaped indices" {
    var builder = try accy.tensor.Builder.init(std.testing.allocator, "lower_shaped_indexing");
    defer builder.deinit();

    const table = try builder.input(.f32, .{ .vocab = 16, .channel = 4 });
    const ids = try builder.input(.i32, .{ .batch = 2, .token = 3 });
    const gathered = try table.gather(ids, .vocab);
    const zero_table = try builder.full(.f32, .{ .vocab = 16, .channel = 4 }, 0.0);
    const out = try zero_table.scatterAdd(ids, gathered, .vocab);
    var program = try builder.finish(&.{out});
    defer program.deinit();

    const lowered = try toSemanticModule(std.testing.allocator, &program);
    defer lowered.deinit();

    try lowered.verify();
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.GatherOp.operation_name,
        ),
    );
    try std.testing.expect(ir.inspection.countOperationsNamed(
        lowered.choir_module,
        accy.choir.dialect.AccyDialect.ReduceOp.operation_name,
    ) >= 1);
}

test "tensor lowering emits semantic scatter add for scheduled kernel path" {
    var builder = try accy.tensor.Builder.init(std.testing.allocator, "lower_semantic_scatter_add");
    defer builder.deinit();

    const table = try builder.input(.f32, .{ .vocab = 16, .channel = 4 });
    const ids = try builder.input(.i32, .{ .token = 3 });
    const gathered = try table.gather(ids, .vocab);
    const zero_table = try builder.full(.f32, .{ .vocab = 16, .channel = 4 }, 0.0);
    const out = try zero_table.scatterAdd(ids, gathered, .vocab);
    var program = try builder.finish(&.{out});
    defer program.deinit();

    const lowered = try toSemanticModuleWithOptions(std.testing.allocator, &program, .{
        .scatter_add = .semantic_kernel,
    });
    defer lowered.deinit();

    try lowered.verify();
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.GatherOp.operation_name,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.ScatterAddOp.operation_name,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.ReduceOp.operation_name,
        ),
    );
}

test "tensor lowering expands sparse cross entropy through semantic reduction" {
    var builder = try accy.tensor.Builder.init(std.testing.allocator, "lower_sparse_cross_entropy");
    defer builder.deinit();

    const logits = try builder.input(.f32, .{ .sample = 6, .vocab = 11 });
    const targets = try builder.input(.i32, .{ .sample = 6 });
    const out = try builder.sparseCrossEntropyLoss(logits, targets, .vocab);
    var program = try builder.finish(&.{out});
    defer program.deinit();

    const lowered = try toSemanticModule(std.testing.allocator, &program);
    defer lowered.deinit();

    try lowered.verify();
    try std.testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.SparseCrossEntropyOp.operation_name,
        ),
    );
    try std.testing.expect(ir.inspection.countOperationsNamed(
        lowered.choir_module,
        accy.choir.dialect.AccyDialect.ReduceOp.operation_name,
    ) >= 2);
}

test "tensor lowering emits semantic sparse cross entropy for scheduled kernel path" {
    var builder = try accy.tensor.Builder.init(
        std.testing.allocator,
        "lower_semantic_sparse_cross_entropy",
    );
    defer builder.deinit();

    const logits = try builder.input(.f32, .{ .sample = 6, .vocab = 11 });
    const targets = try builder.input(.i32, .{ .sample = 6 });
    const out = try builder.sparseCrossEntropyLoss(logits, targets, .vocab);
    var program = try builder.finish(&.{out});
    defer program.deinit();

    const lowered = try toSemanticModuleWithOptions(std.testing.allocator, &program, .{
        .sparse_cross_entropy = .semantic_kernel,
    });
    defer lowered.deinit();

    try lowered.verify();
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.SparseCrossEntropyOp.operation_name,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.ReduceOp.operation_name,
        ),
    );
}

test "tensor executable preparation lowers scheduled sparse cross entropy to catalog call" {
    const allocator = std.testing.allocator;
    var builder = try accy.tensor.Builder.init(
        allocator,
        "prepare_tensor_sparse_cross_entropy_catalog",
    );
    defer builder.deinit();

    const logits = try builder.input(.f32, .{ .sample = 6, .vocab = 11 });
    const targets = try builder.input(.i32, .{ .sample = 6 });
    const out = try builder.sparseCrossEntropyLoss(logits, targets, .vocab);
    var program = try builder.finish(&.{out});
    defer program.deinit();

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = accy.artifact.KernelCallRegistry{ .entries = &.{} };
    var prepared = try prepareFragment(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
        .kernel_call_registry = &registry,
        .row_sparse_cross_entropy_schedule = .{ .thread_blocks = 4 },
    });
    defer prepared.deinit();

    try std.testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(
            prepared.choir_module,
            accy.choir.dialect.AccyDialect.SparseCrossEntropyOp.operation_name,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            prepared.choir_module,
            accy.choir.dialect.AccyDialect.KernelCallOp.operation_name,
        ),
    );
}

test "tensor executable preparation lowers scheduled scatter add to catalog call" {
    const allocator = std.testing.allocator;
    var builder = try accy.tensor.Builder.init(allocator, "prepare_tensor_scatter_add_catalog");
    defer builder.deinit();

    const table = try builder.input(.f32, .{ .vocab = 16, .channel = 4 });
    const ids = try builder.input(.i32, .{ .token = 3 });
    const gathered = try table.gather(ids, .vocab);
    const zero_table = try builder.full(.f32, .{ .vocab = 16, .channel = 4 }, 0.0);
    const out = try zero_table.scatterAdd(ids, gathered, .vocab);
    var program = try builder.finish(&.{out});
    defer program.deinit();

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = accy.artifact.KernelCallRegistry{ .entries = &.{} };
    var prepared = try prepareFragment(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
        .kernel_call_registry = &registry,
        .scatter_add_schedule = .{ .thread_blocks = 4 },
    });
    defer prepared.deinit();

    try std.testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(
            prepared.choir_module,
            accy.choir.dialect.AccyDialect.ScatterAddOp.operation_name,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            prepared.choir_module,
            accy.choir.dialect.AccyDialect.KernelCallOp.operation_name,
        ),
    );
}

fn lowerScanStep(scan_builder: *accy.tensor.Builder, carry: anytype) !@TypeOf(carry) {
    const half = try scan_builder.full(.f32, .{ .lane = 4 }, 0.5);
    return .{
        .x = try (try (try carry.x.mul(carry.x)).mul(half)).add(carry.c),
        .c = carry.c,
    };
}

test "tensor lowering preserves eligible scan as iterate" {
    var builder = try accy.tensor.Builder.init(std.testing.allocator, "lower_scan");
    defer builder.deinit();

    const x0 = try builder.input(.f32, .{ .lane = 4 });
    const c = try builder.input(.f32, .{ .lane = 4 });
    const walked = try builder.scan(.{
        .length = 3,
        .init = .{ .x = x0, .c = c },
        .body = lowerScanStep,
    });
    var program = try builder.finish(&.{ walked.x, walked.c });
    defer program.deinit();

    const lowered = try toSemanticModule(std.testing.allocator, &program);
    defer lowered.deinit();

    try lowered.verify();
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.IterateOp.operation_name,
        ),
    );
}

fn iterateIncrementStep(
    scan_builder: *accy.tensor.Builder,
    carry: accy.tensor.Value,
) !accy.tensor.Value {
    const one = try scan_builder.full(.f32, .{ .lane = 8 }, 1.0);
    return carry.add(one);
}

test "tensor eligible scan prepares as iterate kernel" {
    const allocator = std.testing.allocator;
    var builder = try accy.tensor.Builder.init(allocator, "prepare_scan_iterate");
    defer builder.deinit();

    const x0 = try builder.input(.f32, .{ .lane = 8 });
    const walked = try builder.scan(.{
        .length = 5,
        .init = x0,
        .body = iterateIncrementStep,
    });
    var program = try builder.finish(&.{walked});
    defer program.deinit();

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var prepared = try prepareFragment(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
    });
    defer prepared.deinit();

    try std.testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
    const summary = try prepared.generatedKernelSummary(0);
    try std.testing.expect(std.mem.startsWith(u8, summary.entry_name, "accy_choir_iterate1_cap5"));
}

fn iterateScalarCarryStep(scan_builder: *accy.tensor.Builder, carry: anytype) !@TypeOf(carry) {
    const one = try scan_builder.full(.f32, .{ .lane = 8 }, 1.0);
    const one_step = try scan_builder.scalar(.i32, 1);
    return .{
        .x = try carry.x.add(one),
        .step = try carry.step.add(one_step),
    };
}

test "tensor eligible scan carries scalar loop state in iterate kernel" {
    const allocator = std.testing.allocator;
    var builder = try accy.tensor.Builder.init(allocator, "prepare_scan_iterate_scalar_carry");
    defer builder.deinit();

    const x0 = try builder.input(.f32, .{ .lane = 8 });
    const step0 = try builder.scalar(.i32, 0);
    const walked = try builder.scan(.{
        .length = 5,
        .init = .{ .x = x0, .step = step0 },
        .body = iterateScalarCarryStep,
    });
    var program = try builder.finish(&.{ walked.x, walked.step });
    defer program.deinit();

    const lowered = try toSemanticModule(allocator, &program);
    defer lowered.deinit();
    try lowered.verify();
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.IterateOp.operation_name,
        ),
    );

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var prepared = try prepareFragment(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
    });
    defer prepared.deinit();

    try std.testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
    const summary = try prepared.generatedKernelSummary(0);
    try std.testing.expect(std.mem.startsWith(u8, summary.entry_name, "accy_choir_iterate2_cap5"));
}

fn iterateRandomStep(scan_builder: *accy.tensor.Builder, carry: anytype) !@TypeOf(carry) {
    const seed = try accy.tensor.random.seed(scan_builder, 0x01234567_89abcdef, .{ .threads = 8 });
    const unit = try seed.counterUniform(carry.step, .{ .lane = 8 }, .f32);
    const one_step = try scan_builder.scalar(.i32, 1);
    return .{
        .x = try carry.x.add(unit),
        .step = try carry.step.add(one_step),
    };
}

test "tensor eligible scan inlines counter uniform random in iterate kernel" {
    const allocator = std.testing.allocator;
    var builder = try accy.tensor.Builder.init(allocator, "prepare_scan_iterate_random");
    defer builder.deinit();

    const x0 = try builder.input(.f32, .{ .lane = 8 });
    const step0 = try builder.scalar(.i32, 0);
    const walked = try builder.scan(.{
        .length = 5,
        .init = .{ .x = x0, .step = step0 },
        .body = iterateRandomStep,
    });
    var program = try builder.finish(&.{walked.x});
    defer program.deinit();

    const lowered = try toSemanticModule(allocator, &program);
    defer lowered.deinit();
    try lowered.verify();
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.IterateOp.operation_name,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.KernelCallOp.operation_name,
        ),
    );

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var prepared = try prepareFragment(allocator, state.handle(), &program, .{
        .artifact_format = .cuda_ptx,
    });
    defer prepared.deinit();

    try std.testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
    const summary = try prepared.generatedKernelSummary(0);
    try std.testing.expect(std.mem.startsWith(u8, summary.entry_name, "accy_choir_iterate2_cap5"));
}

test "tensor eligible scan with counter uniform random prepares for CPU object" {
    const allocator = std.testing.allocator;
    var builder = try accy.tensor.Builder.init(allocator, "prepare_scan_iterate_random_cpu");
    defer builder.deinit();

    const x0 = try builder.input(.f32, .{ .lane = 8 });
    const step0 = try builder.scalar(.i32, 0);
    const walked = try builder.scan(.{
        .length = 5,
        .init = .{ .x = x0, .step = step0 },
        .body = iterateRandomStep,
    });
    var program = try builder.finish(&.{walked.x});
    defer program.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    var prepared = try prepareFragment(allocator, state.handle(), &program, .{
        .artifact_format = .cpu_object,
    });
    defer prepared.deinit();

    try std.testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
}

fn iterateRandomTrigStep(scan_builder: *accy.tensor.Builder, carry: anytype) !@TypeOf(carry) {
    const seed = try accy.tensor.random.seed(scan_builder, 0x01234567_89abcdef, .{ .threads = 8 });
    const unit = try seed.counterUniform(carry.step, .{ .lane = 8 }, .f32);
    const tau = try scan_builder.full(.f32, .{ .lane = 8 }, 6.283185307179586);
    const one = try scan_builder.full(.f32, .{ .lane = 8 }, 1.0);
    const zero = try scan_builder.full(.f32, .{ .lane = 8 }, 0.0);
    const cutoff = try scan_builder.full(.f32, .{ .lane = 8 }, 0.001);
    const radius2 = try (try carry.x.mul(carry.x)).add(try carry.y.mul(carry.y));
    const radius = try (try one.sub(try radius2.sqrt())).max(zero);
    const can_move = try radius.compare(.gt, cutoff);
    const inactive = try scan_builder.full(.i1, .{ .lane = 8 }, false);
    const moving = try carry.active.select(can_move, inactive);
    const angle = try unit.mul(tau);
    const next_x = try carry.x.add(try (try angle.cos()).mul(radius));
    const next_y = try carry.y.add(try (try angle.sin()).mul(radius));
    const one_step = try scan_builder.scalar(.i32, 1);
    return .{
        .x = try moving.select(next_x, carry.x),
        .y = try moving.select(next_y, carry.y),
        .active = moving,
        .step = try carry.step.add(one_step),
    };
}

test "tensor eligible scan with random trig mask prepares for CPU object" {
    const allocator = std.testing.allocator;
    var builder = try accy.tensor.Builder.init(allocator, "prepare_scan_iterate_random_trig_cpu");
    defer builder.deinit();

    const x0 = try builder.input(.f32, .{ .lane = 8 });
    const y0 = try builder.input(.f32, .{ .lane = 8 });
    const active0 = try builder.full(.i1, .{ .lane = 8 }, true);
    const step0 = try builder.scalar(.i32, 0);
    const walked = try builder.scan(.{
        .length = 5,
        .init = .{ .x = x0, .y = y0, .active = active0, .step = step0 },
        .body = iterateRandomTrigStep,
    });
    var program = try builder.finish(&.{ walked.x, walked.y });
    defer program.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    var prepared = try prepareFragment(allocator, state.handle(), &program, .{
        .artifact_format = .cpu_object,
    });
    defer prepared.deinit();

    try std.testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
}

fn ineligibleScanStep(
    scan_builder: *accy.tensor.Builder,
    carry: accy.tensor.Value,
) !accy.tensor.Value {
    const generated = try scan_builder.customCall("accy.custom.generate", 1, &.{}, carry.ty);
    return carry.add(generated);
}

test "tensor lowering unrolls ineligible scan operations" {
    var builder = try accy.tensor.Builder.init(std.testing.allocator, "lower_scan_custom_call");
    defer builder.deinit();

    const x0 = try builder.input(.f32, .{ .lane = 4 });
    const walked = try builder.scan(.{
        .length = 3,
        .init = x0,
        .body = ineligibleScanStep,
    });
    var program = try builder.finish(&.{walked});
    defer program.deinit();

    const lowered = try toSemanticModule(std.testing.allocator, &program);
    defer lowered.deinit();

    try lowered.verify();
    try std.testing.expectEqual(
        @as(usize, 0),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.IterateOp.operation_name,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        ir.inspection.countOperationsNamed(
            lowered.choir_module,
            accy.choir.dialect.AccyDialect.KernelCallOp.operation_name,
        ),
    );
}

test "tensor complex scan executable uses bounded host loop launch plan" {
    const allocator = std.testing.allocator;

    var short_program = try reductionBodyScanProgram(allocator, "host_loop_scan_short", 3);
    defer short_program.deinit();
    var long_program = try reductionBodyScanProgram(allocator, "host_loop_scan_long", 7);
    defer long_program.deinit();

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const handle = state.handle();
    const options = FragmentCompilerOptions{ .artifact_format = .cuda_ptx };

    const short_compiled = try compileFragment(allocator, handle, &short_program, options);
    var short_fragment = try accy.executable.loadFragment(
        allocator,
        handle,
        short_compiled,
        options,
    );
    defer short_fragment.deinit();
    const long_compiled = try compileFragment(allocator, handle, &long_program, options);
    var long_fragment = try accy.executable.loadFragment(allocator, handle, long_compiled, options);
    defer long_fragment.deinit();

    var short_graph = try short_fragment.createLaunchGraphPlan(allocator, .{});
    defer short_graph.deinit();
    var long_graph = try long_fragment.createLaunchGraphPlan(allocator, .{});
    defer long_graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), short_graph.loops.len);
    try std.testing.expectEqual(@as(usize, 1), long_graph.loops.len);
    try std.testing.expectEqual(@as(u64, 3), short_graph.loops[0].trip_count);
    try std.testing.expectEqual(@as(u64, 7), long_graph.loops[0].trip_count);
    try std.testing.expectEqual(short_fragment.kernelCount(), long_fragment.kernelCount());
    try std.testing.expectEqual(short_graph.nodes.len, long_graph.nodes.len);
    try std.testing.expect(short_fragment.kernelCount() > 0);
    try std.testing.expect(short_fragment.kernelCount() < 7);

    const input = @as([8]f32, @splat(1.0));
    const bindings = try accy.executable.prepareInvocation(
        long_fragment,
        allocator,
        &.{std.mem.asBytes(&input)},
    );
    defer bindings.deinit();
    try bindings.launch(allocator);

    try std.testing.expectEqual(long_fragment.kernelCount() * 7, state.launch_count);
}

test "tensor lowering accepts zero operand custom calls" {
    var builder = try accy.tensor.Builder.init(
        std.testing.allocator,
        "lower_zero_operand_custom_call",
    );
    defer builder.deinit();

    const ty = try accy.tensor.Type.init(builder.arena.allocator(), .f32, &.{
        .{ .name = "lane", .extent = 4 },
    });
    const out = try builder.customCall("accy.custom.generate", 1, &.{}, ty);
    var program = try builder.finish(&.{out});
    defer program.deinit();

    const lowered = try toSemanticModule(std.testing.allocator, &program);
    defer lowered.deinit();

    try lowered.verify();
}

fn reductionBodyScanStep(
    scan_builder: *accy.tensor.Builder,
    carry: accy.tensor.Value,
) !accy.tensor.Value {
    _ = scan_builder;
    const total = try carry.sum(.lane);
    const lifted = try total.broadcast(.{ .lane = 8 });
    return carry.add(lifted);
}

fn reductionBodyScanProgram(
    allocator: std.mem.Allocator,
    name: []const u8,
    length: i64,
) !program_mod.Program {
    var builder = try accy.tensor.Builder.init(allocator, name);
    defer builder.deinit();

    const x0 = try builder.input(.f32, .{ .lane = 8 });
    const walked = try builder.scan(.{
        .length = length,
        .init = x0,
        .body = reductionBodyScanStep,
    });
    return try builder.finish(&.{walked});
}

const CountLowerAdd = struct {
    count: *usize,

    pub fn bind(self: *@This(), ctx: anytype) !*ir.Value {
        switch (ctx.op.kind) {
            .binary => |binary| {
                if (binary.op == .add) self.count.* += 1;
            },
            else => {},
        }
        return ctx.default();
    }
};

fn toSemanticModuleCountingAdds(
    allocator: std.mem.Allocator,
    program: *const program_mod.Program,
    count: *usize,
) !*accy.choir.SemanticModule {
    var builder = try accy.choir.SemanticBuilder.init(
        allocator,
        accy.choir.SemanticBuilder.ContextLimits.standard,
    );
    errdefer builder.deinit();

    const choir_types = try allocator.alloc(ir.Type, program.valueCount());
    defer allocator.free(choir_types);
    for (program.values, 0..) |ty, index| {
        const shape = try types.extents(allocator, ty.dims);
        defer allocator.free(@constCast(shape));
        choir_types[index] = try builder.tensor(ty.dtype, shape);
    }

    const parameter_types = try allocator.alloc(ir.Type, program.parameters.len);
    defer allocator.free(parameter_types);
    for (program.parameters, 0..) |id, index| {
        parameter_types[index] = choir_types[id.index];
    }

    const result_types = try allocator.alloc(ir.Type, program.outputs.len);
    defer allocator.free(result_types);
    for (program.outputs, 0..) |id, index| {
        result_types[index] = choir_types[id.index];
    }

    var function = try builder.beginFunction(program.name, parameter_types, result_types);
    var scan_state = ScanLoweringState{};
    defer scan_state.deinit(allocator);
    try interpret.run(allocator, program, interpret.layer(
        *ir.Value,
        semantics(allocator, &function, choir_types, &scan_state, .{}),
        CountLowerAdd{ .count = count },
    ));

    return try builder.finish();
}

test "tensor lowering semantics composes with interpreter layers" {
    var builder = try accy.tensor.Builder.init(std.testing.allocator, "lower_layer");
    defer builder.deinit();

    const x = try builder.input(.f32, .{ .lane = 4 });
    const y = try builder.input(.f32, .{ .lane = 4 });
    const out = try x.add(y);
    var program = try builder.finish(&.{out});
    defer program.deinit();

    var add_count: usize = 0;
    const lowered = try toSemanticModuleCountingAdds(std.testing.allocator, &program, &add_count);
    defer lowered.deinit();

    try std.testing.expectEqual(@as(usize, 1), add_count);
    try lowered.verify();
}

test "tensor lowering module attaches to graph interpretation" {
    var builder = try accy.tensor.Builder.init(std.testing.allocator, "lower_module");
    defer builder.deinit();

    const x = try builder.input(.f32, .{ .lane = 4 });
    const y = try builder.input(.f32, .{ .lane = 4 });
    const out = try (try x.add(y)).tanh();
    var program = try builder.finish(&.{out});
    defer program.deinit();

    var graph_builder = try accy.tensor.Builder.init(std.testing.allocator, "lower_module");
    errdefer graph_builder.deinit();

    const graph = interpret.Graph{ .builder = &graph_builder };
    const lowered = try interpret.run(
        std.testing.allocator,
        &program,
        module(std.testing.allocator).attach(graph),
    );
    defer lowered.deinit();

    try lowered.verify();
}

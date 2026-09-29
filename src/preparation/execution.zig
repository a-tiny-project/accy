const std = @import("std");
const choir = @import("choir");

const accy_choir = @import("../choir/root.zig");
const target_product = @import("../target/root.zig");
const kernelization = @import("kernelization/root.zig");
const run_mod = @import("run.zig");
const stage_mod = @import("stage.zig");
const recipe = @import("recipe.zig");
const stage_fingerprint = @import("fingerprint.zig");

const contract = accy_choir.contract;
const dispatch = accy_choir.dispatch;
const kernel_product = accy_choir.gpu;
const memory_product = accy_choir.memory;
const semantic = accy_choir.semantic;
const tensor = accy_choir.tensor;

const ir = choir.ir;
const passes = choir.passes;

pub const PipelineError = error{
    PassFailed,
};

const BackendPreparationRunOptions = run_mod.BackendPreparationRunOptions;
const BackendPreparationStats = run_mod.BackendPreparationStats;

pub fn capturePipelineFailure(
    allocator: std.mem.Allocator,
    failure: ?*run_mod.BackendPreparationFailure,
    pipeline_name: []const u8,
    pm: *const passes.PassManager,
) void {
    const out = failure orelse return;
    if (pm.getLastFailureReproducer()) |reproducer| {
        out.capture(allocator, pipeline_name, reproducer) catch {};
    } else {
        out.deinit(allocator);
        out.pipeline_name = pipeline_name;
    }
}

fn passFailed(
    allocator: std.mem.Allocator,
    failure: ?*run_mod.BackendPreparationFailure,
    pipeline_name: []const u8,
    pm: *const passes.PassManager,
) PipelineError {
    capturePipelineFailure(allocator, failure, pipeline_name, pm);
    return PipelineError.PassFailed;
}

fn preparationPassFailed(
    allocator: std.mem.Allocator,
    options: BackendPreparationRunOptions,
    pipeline_name: []const u8,
    pm: *const passes.PassManager,
) PipelineError {
    return passFailed(allocator, options.failure, pipeline_name, pm);
}

pub const ContractPreparationResult = struct {
    module: *contract.ContractJob,
    elapsed_ns: u64,
    stats: BackendPreparationStats,
    initial_choir_ops: u64,
    semantic_fingerprint: ?u64,
    started_at: i128,
    finished_at: i128,

    pub fn deinit(self: *ContractPreparationResult) void {
        self.module.deinit();
        self.* = undefined;
    }
};

pub const TensorPreparationResult = struct {
    module: *tensor.TensorJob,
    elapsed_ns: u64,
    stats: BackendPreparationStats,

    pub fn deinit(self: *TensorPreparationResult) void {
        self.module.deinit();
        self.* = undefined;
    }
};

pub const DispatchPreparationResult = struct {
    module: *dispatch.DispatchJob,
    elapsed_ns: u64,
    stats: BackendPreparationStats,
    /// A caller reads this field to show whether the dispatch plans of two runs look alike. The
    /// field holds a 64-bit summary of the plans made by the dispatch stage, for display in a run
    /// stamp, the per-stage display record built for people reading a run. No product key or reuse
    /// decision reads it.
    plan_fingerprint: u64,

    pub fn deinit(self: *DispatchPreparationResult) void {
        self.module.deinit();
        self.* = undefined;
    }
};

pub const MemoryPreparationResult = struct {
    module: *memory_product.MemoryJob,
    elapsed_ns: u64,
    stats: BackendPreparationStats,
    /// A caller reads this field to show whether the memory plans of two runs look alike. The field
    /// holds a 64-bit summary of the buffer, memory-space and layout plans made by the memory
    /// stage, for display in run stamps. No product key or reuse decision reads it.
    plan_fingerprint: u64,

    pub fn deinit(self: *MemoryPreparationResult) void {
        self.module.deinit();
        self.* = undefined;
    }
};

pub const KernelPreparationResult = struct {
    module: *kernel_product.KernelJob,
    elapsed_ns: u64,
    stats: BackendPreparationStats,
    /// A caller reads this field to show whether the kernel plans of two runs look alike. The field
    /// holds a 64-bit summary of the kernel outline and generated kernels made by the kernel stage,
    /// for display in run stamps. No product key or reuse decision reads it.
    plan_fingerprint: u64,

    pub fn deinit(self: *KernelPreparationResult) void {
        self.module.deinit();
        self.* = undefined;
    }
};

pub const TargetPreparationResult = struct {
    module: *target_product.TargetJob,
    elapsed_ns: u64,
    stats: BackendPreparationStats,
    finished_at: i128,

    pub fn deinit(self: *TargetPreparationResult) void {
        self.module.deinit();
        self.* = undefined;
    }
};

pub const TargetProductPreparationResult = struct {
    choir_module: *ir.Operation,
    analysis_cache: passes.AnalysisCache,
    kernelization_product: *const kernelization.KernelizationAnalysis,
    elapsed_ns: u64,
    stats: BackendPreparationStats,
    finished_at: i128,

    pub fn deinit(self: *TargetProductPreparationResult) void {
        self.analysis_cache.deinit();
        self.choir_module.erase();
        self.* = undefined;
    }
};

pub fn runTargetPipeline(
    allocator: std.mem.Allocator,
    choir_module: *ir.Operation,
    ctx: *ir.Context,
) !void {
    return try runTargetPipelineWithOptions(allocator, choir_module, ctx, .{});
}

pub fn runTargetPipelineWithOptions(
    allocator: std.mem.Allocator,
    choir_module: *ir.Operation,
    ctx: *ir.Context,
    options: passes.PassManagerRunOptions,
) !void {
    return try runTargetPipelineWithDiagnostics(allocator, choir_module, ctx, options, null);
}

pub fn runTargetPipelineWithDiagnostics(
    allocator: std.mem.Allocator,
    choir_module: *ir.Operation,
    ctx: *ir.Context,
    options: passes.PassManagerRunOptions,
    failure: ?*run_mod.BackendPreparationFailure,
) !void {
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try recipe.configure(&pm, .target, &.{});
    if (pm.runWithOptions(choir_module, ctx, options) == .failure) return passFailed(allocator, failure, stage_mod.target_pipeline_name, &pm);
}

pub fn prepareContractJobFromSemanticModule(
    allocator: std.mem.Allocator,
    module: *semantic.SemanticModule,
    options: BackendPreparationRunOptions,
) !*contract.ContractJob {
    const result = try prepareContractJobFromSemanticModuleWithRun(
        allocator,
        module,
        options,
    );
    return result.module;
}

pub fn prepareTensorJobFromContractJob(
    allocator: std.mem.Allocator,
    module: *contract.ContractJob,
    options: BackendPreparationRunOptions,
) !*tensor.TensorJob {
    const result = try prepareTensorJobFromContractJobWithRun(
        allocator,
        module,
        options,
    );
    return result.module;
}

pub fn prepareDispatchJobFromTensorJob(
    allocator: std.mem.Allocator,
    module: *tensor.TensorJob,
    options: BackendPreparationRunOptions,
) !*dispatch.DispatchJob {
    const result = try prepareDispatchJobFromTensorJobWithRun(
        allocator,
        module,
        options,
    );
    return result.module;
}

pub fn prepareMemoryJobFromDispatchJob(
    allocator: std.mem.Allocator,
    module: *dispatch.DispatchJob,
    options: BackendPreparationRunOptions,
) !*memory_product.MemoryJob {
    const result = try prepareMemoryJobFromDispatchJobWithRun(
        allocator,
        module,
        options,
    );
    return result.module;
}

pub fn prepareKernelJobFromMemoryJob(
    allocator: std.mem.Allocator,
    module: *memory_product.MemoryJob,
    options: BackendPreparationRunOptions,
) !*kernel_product.KernelJob {
    const result = try prepareKernelJobFromMemoryJobWithRun(
        allocator,
        module,
        options,
    );
    return result.module;
}

pub fn prepareTargetJobFromKernelJob(
    allocator: std.mem.Allocator,
    module: *kernel_product.KernelJob,
    options: BackendPreparationRunOptions,
) !*target_product.TargetJob {
    const result = try prepareTargetJobFromKernelJobWithRun(
        allocator,
        module,
        options,
    );
    return result.module;
}

pub fn prepareContractJobFromSemanticModuleWithRun(
    allocator: std.mem.Allocator,
    module: *semantic.SemanticModule,
    options: BackendPreparationRunOptions,
) !ContractPreparationResult {
    var module_owned = true;
    errdefer if (module_owned) module.deinit();

    try module.verify();

    const initial_choir_ops = countOperationTree(module.choir_module);
    const semantic_fingerprint = try module.fingerprint(allocator);

    var analysis_cache = passes.AnalysisCache.init(allocator, null);
    defer analysis_cache.deinit();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    if (options.timing) |timing| try run_mod.addTimingInstrumentation(&pm, timing);
    try recipe.configure(&pm, .contract, &options);

    const contract_start = options.now();
    if (pm.runWithAnalysisCache(
        module.choir_module,
        module.context(),
        &analysis_cache,
        recipe.runOptions(),
    ) == .failure) {
        return preparationPassFailed(allocator, options, stage_mod.contract_pipeline_name, &pm);
    }
    const contract_end = options.now();

    const contract_module = try contract.ContractJob.init(allocator, module);
    module_owned = false;
    return .{
        .module = contract_module,
        .elapsed_ns = nsBetween(contract_start, contract_end),
        .stats = run_mod.backendPreparationStats(pm.stats),
        .initial_choir_ops = initial_choir_ops,
        .semantic_fingerprint = semantic_fingerprint,
        .started_at = contract_start,
        .finished_at = contract_end,
    };
}

pub fn prepareTensorJobFromContractJobWithRun(
    allocator: std.mem.Allocator,
    module: *contract.ContractJob,
    options: BackendPreparationRunOptions,
) !TensorPreparationResult {
    var module_owned = true;
    errdefer if (module_owned) module.deinit();

    try module.verify();

    var analysis_cache = passes.AnalysisCache.init(allocator, null);
    var cache_owned = true;
    errdefer if (cache_owned) analysis_cache.deinit();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    if (options.timing) |timing| try run_mod.addTimingInstrumentation(&pm, timing);
    try recipe.configure(&pm, .tensor, &options);

    const tensor_start = options.now();
    if (pm.runWithAnalysisCache(
        module.choir_module,
        module.context(),
        &analysis_cache,
        recipe.runOptions(),
    ) == .failure) {
        return preparationPassFailed(allocator, options, stage_mod.tensor_pipeline_name, &pm);
    }
    const tensor_end = options.now();

    const tensor_module = try tensor.TensorJob.init(allocator, module, analysis_cache);
    module_owned = false;
    cache_owned = false;
    return .{
        .module = tensor_module,
        .elapsed_ns = nsBetween(tensor_start, tensor_end),
        .stats = run_mod.backendPreparationStats(pm.stats),
    };
}

pub fn prepareDispatchJobFromTensorJobWithRun(
    allocator: std.mem.Allocator,
    module: *tensor.TensorJob,
    options: BackendPreparationRunOptions,
) !DispatchPreparationResult {
    var module_owned = true;
    errdefer if (module_owned) module.deinit();

    try module.verify();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    if (options.timing) |timing| try run_mod.addTimingInstrumentation(&pm, timing);
    try recipe.configure(&pm, .dispatch, &options);

    const dispatch_start = options.now();
    if (pm.runWithAnalysisCache(
        module.choir_module,
        module.context(),
        &module.analysis_cache,
        recipe.runOptions(),
    ) == .failure) {
        return preparationPassFailed(allocator, options, stage_mod.dispatch_pipeline_name, &pm);
    }
    const dispatch_end = options.now();

    const plan_fingerprint = try stage_fingerprint.dispatch(
        allocator,
        module,
        stage_mod.dispatch_pipeline_name,
    );
    const dispatch_module = try dispatch.DispatchJob.init(allocator, module);
    module_owned = false;
    return .{
        .module = dispatch_module,
        .elapsed_ns = nsBetween(dispatch_start, dispatch_end),
        .stats = run_mod.backendPreparationStats(pm.stats),
        .plan_fingerprint = plan_fingerprint,
    };
}

pub fn prepareMemoryJobFromDispatchJobWithRun(
    allocator: std.mem.Allocator,
    module: *dispatch.DispatchJob,
    options: BackendPreparationRunOptions,
) !MemoryPreparationResult {
    var module_owned = true;
    errdefer if (module_owned) module.deinit();

    try module.verify();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    if (options.timing) |timing| try run_mod.addTimingInstrumentation(&pm, timing);
    try recipe.configure(&pm, .memory, &options);

    const memory_start = options.now();
    if (pm.runWithAnalysisCache(
        module.choir_module,
        module.context(),
        &module.tensor_module.analysis_cache,
        recipe.runOptions(),
    ) == .failure) {
        return preparationPassFailed(allocator, options, stage_mod.memory_pipeline_name, &pm);
    }
    const memory_end = options.now();

    const plan_fingerprint = try stage_fingerprint.memory(
        allocator,
        module,
        stage_mod.memory_pipeline_name,
    );
    const memory_module = try memory_product.MemoryJob.init(allocator, module);
    module_owned = false;
    return .{
        .module = memory_module,
        .elapsed_ns = nsBetween(memory_start, memory_end),
        .stats = run_mod.backendPreparationStats(pm.stats),
        .plan_fingerprint = plan_fingerprint,
    };
}

pub fn prepareKernelJobFromMemoryJobWithRun(
    allocator: std.mem.Allocator,
    module: *memory_product.MemoryJob,
    options: BackendPreparationRunOptions,
) !KernelPreparationResult {
    var module_owned = true;
    errdefer if (module_owned) module.deinit();

    try module.verify();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    if (options.timing) |timing| try run_mod.addTimingInstrumentation(&pm, timing);
    try recipe.configure(&pm, .kernel, &options);

    try recipe.applyTargetOptions(allocator, module.choir_module, options);
    const kernel_start = options.now();
    if (pm.runWithAnalysisCache(
        module.choir_module,
        module.context(),
        &module.dispatch_module.tensor_module.analysis_cache,
        recipe.runOptions(),
    ) == .failure) {
        return preparationPassFailed(allocator, options, stage_mod.kernel_pipeline_name, &pm);
    }
    const kernel_end = options.now();

    const plan_fingerprint = try stage_fingerprint.kernel(
        allocator,
        module,
        stage_mod.kernel_pipeline_name,
    );
    const kernel_module = try kernel_product.KernelJob.init(allocator, module);
    module_owned = false;
    return .{
        .module = kernel_module,
        .elapsed_ns = nsBetween(kernel_start, kernel_end),
        .stats = run_mod.backendPreparationStats(pm.stats),
        .plan_fingerprint = plan_fingerprint,
    };
}

pub fn prepareTargetJobFromKernelJobWithRun(
    allocator: std.mem.Allocator,
    module: *kernel_product.KernelJob,
    options: BackendPreparationRunOptions,
) !TargetPreparationResult {
    var module_owned = true;
    errdefer if (module_owned) module.deinit();

    var target_result = try prepareTargetProductFromKernelJobWithRun(allocator, module, options);
    var target_result_owned = true;
    errdefer if (target_result_owned) target_result.deinit();
    const target_module = try target_product.TargetJob.init(
        allocator,
        module,
        target_result.choir_module,
        target_result.analysis_cache,
        target_result.kernelization_product,
    );
    target_result_owned = false;
    module_owned = false;
    return .{
        .module = target_module,
        .elapsed_ns = target_result.elapsed_ns,
        .stats = target_result.stats,
        .finished_at = target_result.finished_at,
    };
}

pub fn prepareTargetProductFromKernelJobWithRun(
    allocator: std.mem.Allocator,
    module: *kernel_product.KernelJob,
    options: BackendPreparationRunOptions,
) !TargetProductPreparationResult {
    try module.verify();

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    if (options.timing) |timing| try run_mod.addTimingInstrumentation(&pm, timing);
    try recipe.configure(&pm, .target, &options);

    const target_start = options.now();
    var kernel_pass_ctx = module.passContext();
    defer kernel_pass_ctx.deinit();
    const kernelization_product = try kernelization.getKernelizationAnalysis(&kernel_pass_ctx, module.choir_module);

    const target_choir_module = try module.choir_module.clone();
    var target_choir_module_owned = true;
    errdefer if (target_choir_module_owned) target_choir_module.erase();

    var target_analysis_cache = passes.AnalysisCache.init(allocator, null);
    var target_cache_owned = true;
    errdefer if (target_cache_owned) target_analysis_cache.deinit();

    try recipe.applyTargetOptions(allocator, target_choir_module, options);
    if (pm.runWithAnalysisCache(
        target_choir_module,
        module.context(),
        &target_analysis_cache,
        recipe.runOptions(),
    ) == .failure) {
        return preparationPassFailed(allocator, options, stage_mod.target_pipeline_name, &pm);
    }
    const target_end = options.now();

    target_choir_module_owned = false;
    target_cache_owned = false;
    return .{
        .choir_module = target_choir_module,
        .analysis_cache = target_analysis_cache,
        .kernelization_product = kernelization_product,
        .elapsed_ns = nsBetween(target_start, target_end),
        .stats = run_mod.backendPreparationStats(pm.stats),
        .finished_at = target_end,
    };
}

pub fn nsBetween(start: i128, end: i128) u64 {
    if (end <= start) return 0;
    const elapsed = end - start;
    if (elapsed > std.math.maxInt(u64)) return std.math.maxInt(u64);
    return @intCast(elapsed);
}

pub fn countOperationTree(op: *ir.Operation) u64 {
    var count: u64 = 1;
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var op_node = block.operations.head;
            while (op_node) |node| {
                const child: *ir.Operation = @ptrCast(@alignCast(node));
                count +|= countOperationTree(child);
                op_node = child.next_op;
            }
        }
    }
    return count;
}

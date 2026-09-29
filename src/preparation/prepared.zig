const std = @import("std");
const choir = @import("choir");

const accy_choir = @import("../choir/root.zig");
const target_product = @import("../target/root.zig");
const execution_mod = @import("execution.zig");
const kernelization = @import("kernelization/root.zig");
const product_mod = @import("product.zig");
const run_mod = @import("run.zig");

const contract = accy_choir.contract;
const semantic = accy_choir.semantic;

const ir = choir.ir;
const passes = choir.passes;

const BackendPreparationProductStamps = product_mod.BackendPreparationProductStamps;
const BackendPreparationRun = run_mod.BackendPreparationRun;
const BackendPreparationRunOptions = run_mod.BackendPreparationRunOptions;
const BackendPreparationStats = run_mod.BackendPreparationStats;
const ContractPreparationResult = execution_mod.ContractPreparationResult;
const DispatchPreparationResult = execution_mod.DispatchPreparationResult;
const KernelPreparationResult = execution_mod.KernelPreparationResult;
const MemoryPreparationResult = execution_mod.MemoryPreparationResult;
const TargetPreparationResult = execution_mod.TargetPreparationResult;
const TensorPreparationResult = execution_mod.TensorPreparationResult;

const countOperationTree = execution_mod.countOperationTree;
const nsBetween = execution_mod.nsBetween;
const prepareContractJobFromSemanticModuleWithRun =
    execution_mod.prepareContractJobFromSemanticModuleWithRun;
const prepareDispatchJobFromTensorJobWithRun =
    execution_mod.prepareDispatchJobFromTensorJobWithRun;
const prepareKernelJobFromMemoryJobWithRun =
    execution_mod.prepareKernelJobFromMemoryJobWithRun;
const prepareMemoryJobFromDispatchJobWithRun =
    execution_mod.prepareMemoryJobFromDispatchJobWithRun;
const prepareTargetJobFromKernelJobWithRun =
    execution_mod.prepareTargetJobFromKernelJobWithRun;
const prepareTensorJobFromContractJobWithRun =
    execution_mod.prepareTensorJobFromContractJobWithRun;

pub const BackendPreparedJob = struct {
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    choir_module: *ir.Operation,
    target_module: ?*target_product.TargetJob,
    run: BackendPreparationRun,

    pub fn deinit(self: *BackendPreparedJob) void {
        if (self.target_module) |module| module.deinit();
        self.* = undefined;
    }

    pub fn passContext(self: *BackendPreparedJob) passes.PassContext {
        return self.target_module.?.passContext();
    }

    pub fn targetModule(self: *const BackendPreparedJob) !*target_product.TargetJob {
        return self.target_module orelse error.MissingTargetProduct;
    }

    pub fn kernelizationProduct(self: *const BackendPreparedJob) !*const kernelization.KernelizationAnalysis {
        return (try self.targetModule()).kernelizationProduct();
    }

    pub fn generatedKernelCount(self: *const BackendPreparedJob) !usize {
        const product = try self.kernelizationProduct();
        return product.kernelCount();
    }

    pub fn productStamps(self: *const BackendPreparedJob) !BackendPreparationProductStamps {
        return product_mod.stampsFromRun(self.run);
    }

    pub fn generatedKernelSummary(
        self: *const BackendPreparedJob,
        kernel_index: usize,
    ) !kernelization.GeneratedKernelSummary {
        const product = try self.kernelizationProduct();
        return product.kernelSummary(kernel_index);
    }

    pub fn generatedKernelProgram(
        self: *const BackendPreparedJob,
        kernel_index: usize,
    ) !*const kernelization.GeneratedKernelProgram {
        const product = try self.kernelizationProduct();
        return product.kernelProgram(kernel_index);
    }

    pub fn generatedKernelSummaryForWork(
        self: *const BackendPreparedJob,
        work_item_id: usize,
    ) !kernelization.GeneratedKernelSummary {
        const product = try self.kernelizationProduct();
        return product.kernelSummaryForWork(work_item_id);
    }

    pub fn generatedKernelProgramForWork(
        self: *const BackendPreparedJob,
        work_item_id: usize,
    ) !*const kernelization.GeneratedKernelProgram {
        const product = try self.kernelizationProduct();
        return product.kernelProgramForWork(work_item_id);
    }

    pub fn copyGeneratedKernelSummaries(
        self: *const BackendPreparedJob,
        result_allocator: std.mem.Allocator,
    ) !kernelization.GeneratedKernelSummaries {
        const product = try self.kernelizationProduct();
        return product.copyKernelSummaries(result_allocator);
    }
};

pub fn runBackendPreparationPipelineFromSemanticModule(
    allocator: std.mem.Allocator,
    module: *semantic.SemanticModule,
    options: BackendPreparationRunOptions,
) !BackendPreparationRun {
    var prepared = try prepareBackendJobFromSemanticModule(allocator, module, options);
    defer prepared.deinit();
    return prepared.run;
}

pub fn prepareBackendJobFromSemanticModule(
    allocator: std.mem.Allocator,
    module: *semantic.SemanticModule,
    options: BackendPreparationRunOptions,
) !BackendPreparedJob {
    return try prepareOwnedSemanticModuleForBackend(
        allocator,
        module,
        options,
        options.now(),
    );
}

pub fn prepareBackendJobFromContractJob(
    allocator: std.mem.Allocator,
    module: *contract.ContractJob,
    options: BackendPreparationRunOptions,
) !BackendPreparedJob {
    const initial_choir_ops = countOperationTree(module.choir_module);
    const total_start = options.now();
    const tensor_result = try prepareTensorJobFromContractJobWithRun(
        allocator,
        module,
        options,
    );
    return try prepareBackendJobFromTensorPreparationResult(
        allocator,
        tensor_result,
        options,
        0,
        .{},
        initial_choir_ops,
        null,
        total_start,
    );
}

fn prepareOwnedSemanticModuleForBackend(
    allocator: std.mem.Allocator,
    module: *semantic.SemanticModule,
    options: BackendPreparationRunOptions,
    total_start: i128,
) !BackendPreparedJob {
    const contract_result = try prepareContractJobFromSemanticModuleWithRun(allocator, module, options);
    return try prepareBackendJobFromContractPreparationResult(allocator, contract_result, options, total_start);
}

pub fn prepareBackendJobFromContractPreparationResult(
    allocator: std.mem.Allocator,
    result: ContractPreparationResult,
    options: BackendPreparationRunOptions,
    total_start: i128,
) !BackendPreparedJob {
    var contract_result = result;
    var contract_owned = true;
    errdefer if (contract_owned) contract_result.deinit();

    const contract_ns = result.elapsed_ns;
    const contract_stats = result.stats;
    const initial_choir_ops = result.initial_choir_ops;
    const semantic_fingerprint = result.semantic_fingerprint;
    contract_owned = false;
    const tensor_result = try prepareTensorJobFromContractJobWithRun(
        allocator,
        contract_result.module,
        options,
    );
    return try prepareBackendJobFromTensorPreparationResult(
        allocator,
        tensor_result,
        options,
        contract_ns,
        contract_stats,
        initial_choir_ops,
        semantic_fingerprint,
        total_start,
    );
}

pub fn prepareBackendJobFromTensorPreparationResult(
    allocator: std.mem.Allocator,
    result: TensorPreparationResult,
    options: BackendPreparationRunOptions,
    contract_ns: u64,
    contract_stats: BackendPreparationStats,
    initial_choir_ops: u64,
    semantic_fingerprint: ?u64,
    total_start: i128,
) !BackendPreparedJob {
    var tensor_result = result;
    var tensor_owned = true;
    errdefer if (tensor_owned) tensor_result.deinit();

    const tensor_ns = result.elapsed_ns;
    const tensor_stats = result.stats;
    tensor_owned = false;
    const dispatch_result = try prepareDispatchJobFromTensorJobWithRun(
        allocator,
        tensor_result.module,
        options,
    );
    return try prepareBackendJobFromDispatchPreparationResult(
        allocator,
        dispatch_result,
        options,
        contract_ns,
        contract_stats,
        tensor_ns,
        tensor_stats,
        initial_choir_ops,
        semantic_fingerprint,
        total_start,
    );
}

pub fn prepareBackendJobFromDispatchPreparationResult(
    allocator: std.mem.Allocator,
    result: DispatchPreparationResult,
    options: BackendPreparationRunOptions,
    contract_ns: u64,
    contract_stats: BackendPreparationStats,
    tensor_ns: u64,
    tensor_stats: BackendPreparationStats,
    initial_choir_ops: u64,
    semantic_fingerprint: ?u64,
    total_start: i128,
) !BackendPreparedJob {
    var dispatch_result = result;
    var dispatch_owned = true;
    errdefer if (dispatch_owned) dispatch_result.deinit();

    const dispatch_ns = result.elapsed_ns;
    const dispatch_stats = result.stats;
    const dispatch_fingerprint = result.plan_fingerprint;
    dispatch_owned = false;
    const memory_result = try prepareMemoryJobFromDispatchJobWithRun(
        allocator,
        dispatch_result.module,
        options,
    );
    return try prepareBackendJobFromMemoryPreparationResult(
        allocator,
        memory_result,
        options,
        contract_ns,
        contract_stats,
        tensor_ns,
        tensor_stats,
        dispatch_ns,
        dispatch_stats,
        dispatch_fingerprint,
        initial_choir_ops,
        semantic_fingerprint,
        total_start,
    );
}

pub fn prepareBackendJobFromMemoryPreparationResult(
    allocator: std.mem.Allocator,
    result: MemoryPreparationResult,
    options: BackendPreparationRunOptions,
    contract_ns: u64,
    contract_stats: BackendPreparationStats,
    tensor_ns: u64,
    tensor_stats: BackendPreparationStats,
    dispatch_ns: u64,
    dispatch_stats: BackendPreparationStats,
    dispatch_fingerprint: u64,
    initial_choir_ops: u64,
    semantic_fingerprint: ?u64,
    total_start: i128,
) !BackendPreparedJob {
    var memory_result = result;
    var memory_owned = true;
    errdefer if (memory_owned) memory_result.deinit();

    const memory_ns = result.elapsed_ns;
    const memory_stats = result.stats;
    const memory_fingerprint = result.plan_fingerprint;
    memory_owned = false;
    const kernel_result = try prepareKernelJobFromMemoryJobWithRun(
        allocator,
        memory_result.module,
        options,
    );
    return try prepareBackendJobFromKernelPreparationResult(
        allocator,
        kernel_result,
        options,
        contract_ns,
        contract_stats,
        tensor_ns,
        tensor_stats,
        dispatch_ns,
        dispatch_stats,
        dispatch_fingerprint,
        memory_ns,
        memory_stats,
        memory_fingerprint,
        initial_choir_ops,
        semantic_fingerprint,
        total_start,
    );
}

pub fn prepareBackendJobFromKernelPreparationResult(
    allocator: std.mem.Allocator,
    result: KernelPreparationResult,
    options: BackendPreparationRunOptions,
    contract_ns: u64,
    contract_stats: BackendPreparationStats,
    tensor_ns: u64,
    tensor_stats: BackendPreparationStats,
    dispatch_ns: u64,
    dispatch_stats: BackendPreparationStats,
    dispatch_fingerprint: u64,
    memory_ns: u64,
    memory_stats: BackendPreparationStats,
    memory_fingerprint: u64,
    initial_choir_ops: u64,
    semantic_fingerprint: ?u64,
    total_start: i128,
) !BackendPreparedJob {
    var kernel_result = result;
    var kernel_owned = true;
    errdefer if (kernel_owned) kernel_result.deinit();

    const kernel_ns = result.elapsed_ns;
    const kernel_stats = result.stats;
    const kernel_fingerprint = result.plan_fingerprint;
    kernel_owned = false;
    const target_result = try prepareTargetJobFromKernelJobWithRun(
        allocator,
        kernel_result.module,
        options,
    );
    return try prepareBackendJobFromTargetPreparationResult(
        allocator,
        target_result,
        options,
        contract_ns,
        contract_stats,
        tensor_ns,
        tensor_stats,
        dispatch_ns,
        dispatch_stats,
        dispatch_fingerprint,
        memory_ns,
        memory_stats,
        memory_fingerprint,
        kernel_ns,
        kernel_stats,
        kernel_fingerprint,
        initial_choir_ops,
        semantic_fingerprint,
        total_start,
    );
}

pub fn prepareBackendJobFromTargetPreparationResult(
    allocator: std.mem.Allocator,
    result: TargetPreparationResult,
    options: BackendPreparationRunOptions,
    contract_ns: u64,
    contract_stats: BackendPreparationStats,
    tensor_ns: u64,
    tensor_stats: BackendPreparationStats,
    dispatch_ns: u64,
    dispatch_stats: BackendPreparationStats,
    dispatch_fingerprint: u64,
    memory_ns: u64,
    memory_stats: BackendPreparationStats,
    memory_fingerprint: u64,
    kernel_ns: u64,
    kernel_stats: BackendPreparationStats,
    kernel_fingerprint: u64,
    initial_choir_ops: u64,
    semantic_fingerprint: ?u64,
    total_start: i128,
) !BackendPreparedJob {
    var target_result = result;
    var target_owned = true;
    errdefer if (target_owned) target_result.deinit();

    target_owned = false;
    return try prepareOwnedTargetJob(
        allocator,
        target_result.module,
        options,
        contract_ns,
        contract_stats,
        tensor_ns,
        tensor_stats,
        dispatch_ns,
        dispatch_stats,
        dispatch_fingerprint,
        memory_ns,
        memory_stats,
        memory_fingerprint,
        kernel_ns,
        kernel_stats,
        kernel_fingerprint,
        result.elapsed_ns,
        result.stats,
        initial_choir_ops,
        semantic_fingerprint,
        total_start,
        result.finished_at,
    );
}

fn prepareOwnedTargetJob(
    allocator: std.mem.Allocator,
    module: *target_product.TargetJob,
    options: BackendPreparationRunOptions,
    contract_ns: u64,
    contract_stats: BackendPreparationStats,
    tensor_ns: u64,
    tensor_stats: BackendPreparationStats,
    dispatch_ns: u64,
    dispatch_stats: BackendPreparationStats,
    dispatch_fingerprint: u64,
    memory_ns: u64,
    memory_stats: BackendPreparationStats,
    memory_fingerprint: u64,
    kernel_ns: u64,
    kernel_stats: BackendPreparationStats,
    kernel_fingerprint: u64,
    target_ns: u64,
    target_stats: BackendPreparationStats,
    initial_choir_ops: u64,
    semantic_fingerprint: ?u64,
    total_start: i128,
    total_end: i128,
) !BackendPreparedJob {
    var module_owned = true;
    errdefer if (module_owned) module.deinit();

    try module.verify();
    const final_choir_ops = countOperationTree(module.choir_module);

    var prepared = BackendPreparedJob{
        .allocator = allocator,
        .ctx = module.context(),
        .choir_module = module.choir_module,
        .target_module = module,
        .run = undefined,
    };

    prepared.run = .{
        .total_ns = nsBetween(total_start, total_end),
        .contract_ns = contract_ns,
        .tensor_ns = tensor_ns,
        .dispatch_ns = dispatch_ns,
        .memory_ns = memory_ns,
        .kernel_ns = kernel_ns,
        .target_ns = target_ns,
        .initial_choir_ops = initial_choir_ops,
        .final_choir_ops = final_choir_ops,
        .semantic_fingerprint = semantic_fingerprint,
        .contract_fingerprint = module.kernel_module.memory_module.dispatch_module.tensor_module.contract_module.fingerprint(),
        .tensor_fingerprint = module.kernel_module.memory_module.dispatch_module.tensor_module.fingerprint(),
        .dispatch_fingerprint = dispatch_fingerprint,
        .memory_fingerprint = memory_fingerprint,
        .kernel_fingerprint = kernel_fingerprint,
        .target_fingerprint = module.fingerprint(),
        .contract_stats = contract_stats,
        .tensor_stats = tensor_stats,
        .dispatch_stats = dispatch_stats,
        .memory_stats = memory_stats,
        .kernel_stats = kernel_stats,
        .target_stats = target_stats,
        .target_profile = options.target_profile,
    };
    module_owned = false;
    return prepared;
}

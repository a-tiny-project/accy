const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const backend_legalization = @import("backend.zig");
const canonicalization = @import("canonicalization.zig");
const saturation = @import("saturation.zig");
const accy_choir = @import("../choir/root.zig");
const target_product = @import("../target/root.zig");
const dialect_mod = accy_choir.dialect;
const execution_mod = @import("execution.zig");
const library_preparation = @import("library.zig");
const kernelization = @import("kernelization/root.zig");
const kernel_outlining = @import("outlining/root.zig");
const contract = accy_choir.contract;
const dispatch = accy_choir.dispatch;
const kernel_product = accy_choir.gpu;
const memory_product = accy_choir.memory;
const semantic = accy_choir.semantic;
const tensor = accy_choir.tensor;
const schedule_planning = @import("schedule/root.zig");
const prepared_mod = @import("prepared.zig");
const product_mod = @import("product.zig");
const run_mod = @import("run.zig");
const stage_mod = @import("stage.zig");
const target_profile = @import("target.zig");

const ir = choir.ir;
const passes = choir.passes;

pub const BackendTargetProfile = target_profile.BackendTargetProfile;
pub const canonicalizeModule = canonicalization.canonicalizeModule;
pub const saturateTensorOperations = saturation.saturateTensorOperations;
pub const setBackendTargetProfile = target_profile.setBackendTargetProfile;
pub const readBackendTargetProfile = target_profile.readBackendTargetProfile;
pub const KernelLibraryLowering = library_preparation.KernelLibraryLowering;
pub const ActivationLoweringOptions = stage_mod.ActivationLoweringOptions;
pub const EinsumLoweringOptions = stage_mod.EinsumLoweringOptions;
pub const IndexingLoweringOptions = stage_mod.IndexingLoweringOptions;
pub const TensorLoweringOptions = stage_mod.TensorLoweringOptions;
pub const backend_legalization_pass_name = stage_mod.backend_legalization_pass_name;
pub const bufferization_planning_pass_name = stage_mod.bufferization_planning_pass_name;
pub const canonicalization_pass_name = stage_mod.canonicalization_pass_name;
pub const constant_folding_pass_name = stage_mod.constant_folding_pass_name;
pub const saturation_pass_name = stage_mod.saturation_pass_name;
pub const dtype_legalization_pass_name = stage_mod.dtype_legalization_pass_name;
pub const activation_lowering_pass_name = stage_mod.activation_lowering_pass_name;
pub const einsum_lowering_pass_name = stage_mod.einsum_lowering_pass_name;
pub const indexing_lowering_pass_name = stage_mod.indexing_lowering_pass_name;
pub const loss_lowering_pass_name = stage_mod.loss_lowering_pass_name;
pub const fusion_planning_pass_name = stage_mod.fusion_planning_pass_name;
pub const kernelization_pass_name = stage_mod.kernelization_pass_name;
pub const kernel_outlining_planning_pass_name = stage_mod.kernel_outlining_planning_pass_name;
pub const layout_planning_pass_name = stage_mod.layout_planning_pass_name;
pub const memory_space_planning_pass_name = stage_mod.memory_space_planning_pass_name;
pub const schedule_planning_pass_name = stage_mod.schedule_planning_pass_name;
pub const shape_layout_pass_name = stage_mod.shape_layout_pass_name;

pub const PipelineError = execution_mod.PipelineError;

pub const BackendPreparationStats = run_mod.BackendPreparationStats;
pub const BackendPreparationFailureKind = run_mod.BackendPreparationFailureKind;
pub const BackendPreparationFailure = run_mod.BackendPreparationFailure;
pub const BackendPreparationTiming = run_mod.BackendPreparationTiming;
pub const BackendPreparationRunOptions = run_mod.BackendPreparationRunOptions;
pub const BackendPreparationRun = run_mod.BackendPreparationRun;

pub const BackendPreparationProductStamps = product_mod.BackendPreparationProductStamps;
pub const BackendPreparationProductKeys = product_mod.BackendPreparationProductKeys;
pub const BackendPreparedModule = product_mod.BackendPreparedModule;
pub const ContractPreparationResult = execution_mod.ContractPreparationResult;
pub const TensorPreparationResult = execution_mod.TensorPreparationResult;
pub const DispatchPreparationResult = execution_mod.DispatchPreparationResult;
pub const MemoryPreparationResult = execution_mod.MemoryPreparationResult;
pub const KernelPreparationResult = execution_mod.KernelPreparationResult;
pub const TargetPreparationResult = execution_mod.TargetPreparationResult;
pub const BackendPreparedJob = prepared_mod.BackendPreparedJob;

pub const backendLegalizationPass = stage_mod.backendLegalizationPass;
pub const bufferizationPlanningPass = stage_mod.bufferizationPlanningPass;
pub const canonicalizationPass = stage_mod.canonicalizationPass;
pub const shapeLayoutPropagationPass = stage_mod.shapeLayoutPropagationPass;
pub const constantFoldingPass = stage_mod.constantFoldingPass;
pub const tensorSaturationPass = stage_mod.tensorSaturationPass;
pub const dtypeLegalizationPass = stage_mod.dtypeLegalizationPass;
pub const activationLoweringPass = stage_mod.activationLoweringPass;
pub const activationLoweringPassWithOptions = stage_mod.activationLoweringPassWithOptions;
pub const einsumLoweringPass = stage_mod.einsumLoweringPass;
pub const einsumLoweringPassWithOptions = stage_mod.einsumLoweringPassWithOptions;
pub const indexingLoweringPass = stage_mod.indexingLoweringPass;
pub const indexingLoweringPassWithOptions = stage_mod.indexingLoweringPassWithOptions;
pub const lossLoweringPass = stage_mod.lossLoweringPass;
pub const lossLoweringPassWithOptions = stage_mod.lossLoweringPassWithOptions;
pub const fusionPlanningPass = stage_mod.fusionPlanningPass;
pub const schedulePlanningPass = stage_mod.schedulePlanningPass;
pub const kernelOutliningPlanningPass = stage_mod.kernelOutliningPlanningPass;
pub const kernelizationPass = stage_mod.kernelizationPass;
pub const memorySpacePlanningPass = stage_mod.memorySpacePlanningPass;
pub const layoutPlanningPass = stage_mod.layoutPlanningPass;
pub const BackendPreparationStage = stage_mod.BackendPreparationStage;
pub const contract_pipeline_name = stage_mod.contract_pipeline_name;
pub const contract_pipeline_description = stage_mod.contract_pipeline_description;
pub const tensor_pipeline_name = stage_mod.tensor_pipeline_name;
pub const tensor_pipeline_description = stage_mod.tensor_pipeline_description;
pub const dispatch_pipeline_name = stage_mod.dispatch_pipeline_name;
pub const dispatch_pipeline_description = stage_mod.dispatch_pipeline_description;
pub const memory_pipeline_name = stage_mod.memory_pipeline_name;
pub const memory_pipeline_description = stage_mod.memory_pipeline_description;
pub const kernel_pipeline_name = stage_mod.kernel_pipeline_name;
pub const kernel_pipeline_description = stage_mod.kernel_pipeline_description;
pub const target_pipeline_name = stage_mod.target_pipeline_name;
pub const target_pipeline_description = stage_mod.target_pipeline_description;
pub const contract_stages = stage_mod.contract_stages;
pub const tensor_stages = stage_mod.tensor_stages;
pub const dispatch_stages = stage_mod.dispatch_stages;
pub const memory_stages = stage_mod.memory_stages;
pub const kernel_stages = stage_mod.kernel_stages;
pub const target_stages = stage_mod.target_stages;
pub const contract_pipeline_registration = stage_mod.contract_pipeline_registration;
pub const tensor_pipeline_registration = stage_mod.tensor_pipeline_registration;
pub const dispatch_pipeline_registration = stage_mod.dispatch_pipeline_registration;
pub const memory_pipeline_registration = stage_mod.memory_pipeline_registration;
pub const kernel_pipeline_registration = stage_mod.kernel_pipeline_registration;
pub const target_pipeline_registration = stage_mod.target_pipeline_registration;
pub const contract_pass_registrations = stage_mod.contract_pass_registrations;
pub const tensor_pass_registrations = stage_mod.tensor_pass_registrations;
pub const dispatch_pass_registrations = stage_mod.dispatch_pass_registrations;
pub const memory_pass_registrations = stage_mod.memory_pass_registrations;
pub const kernel_pass_registrations = stage_mod.kernel_pass_registrations;
pub const target_pass_registrations = stage_mod.target_pass_registrations;
pub const accy_choir_pass_registrations = stage_mod.accy_choir_pass_registrations;
pub const accy_choir_package_extension = stage_mod.accy_choir_package_extension;
pub const contract_pass_plan = stage_mod.contract_pass_plan;
pub const tensor_pass_plan = stage_mod.tensor_pass_plan;
pub const dispatch_pass_plan = stage_mod.dispatch_pass_plan;
pub const memory_pass_plan = stage_mod.memory_pass_plan;
pub const kernel_pass_plan = stage_mod.kernel_pass_plan;
pub const target_pass_plan = stage_mod.target_pass_plan;
pub const contract_pass_count = stage_mod.contract_pass_count;
pub const contract_analysis_count = stage_mod.contract_analysis_count;
pub const tensor_pass_count = stage_mod.tensor_pass_count;
pub const tensor_analysis_count = stage_mod.tensor_analysis_count;
pub const dispatch_pass_count = stage_mod.dispatch_pass_count;
pub const dispatch_analysis_count = stage_mod.dispatch_analysis_count;
pub const memory_pass_count = stage_mod.memory_pass_count;
pub const memory_analysis_count = stage_mod.memory_analysis_count;
pub const kernel_pass_count = stage_mod.kernel_pass_count;
pub const kernel_analysis_count = stage_mod.kernel_analysis_count;
pub const target_pass_count = stage_mod.target_pass_count;
pub const target_analysis_count = stage_mod.target_analysis_count;
pub const contractPassName = stage_mod.contractPassName;
pub const contractAnalysisName = stage_mod.contractAnalysisName;
pub const tensorPassName = stage_mod.tensorPassName;
pub const tensorAnalysisName = stage_mod.tensorAnalysisName;
pub const dispatchPassName = stage_mod.dispatchPassName;
pub const dispatchAnalysisName = stage_mod.dispatchAnalysisName;
pub const memoryPassName = stage_mod.memoryPassName;
pub const memoryAnalysisName = stage_mod.memoryAnalysisName;
pub const kernelPassName = stage_mod.kernelPassName;
pub const kernelAnalysisName = stage_mod.kernelAnalysisName;
pub const targetPassName = stage_mod.targetPassName;
pub const targetAnalysisName = stage_mod.targetAnalysisName;
pub const addContractPipeline = stage_mod.addContractPipeline;
pub const addTensorPipeline = stage_mod.addTensorPipeline;
pub const addTensorPipelineWithOptions = stage_mod.addTensorPipelineWithOptions;
pub const addDispatchPipeline = stage_mod.addDispatchPipeline;
pub const addMemoryPipeline = stage_mod.addMemoryPipeline;
pub const addKernelPipeline = stage_mod.addKernelPipeline;
pub const addTargetPipeline = stage_mod.addTargetPipeline;

pub const runTargetPipeline = execution_mod.runTargetPipeline;
pub const runTargetPipelineWithOptions = execution_mod.runTargetPipelineWithOptions;
pub const runTargetPipelineWithDiagnostics = execution_mod.runTargetPipelineWithDiagnostics;

pub const runBackendPreparationPipelineFromSemanticModule =
    prepared_mod.runBackendPreparationPipelineFromSemanticModule;
pub const prepareBackendJobFromSemanticModule =
    prepared_mod.prepareBackendJobFromSemanticModule;

pub const prepareContractJobFromSemanticModule = execution_mod.prepareContractJobFromSemanticModule;
pub const prepareTensorJobFromContractJob = execution_mod.prepareTensorJobFromContractJob;
pub const prepareDispatchJobFromTensorJob = execution_mod.prepareDispatchJobFromTensorJob;
pub const prepareMemoryJobFromDispatchJob = execution_mod.prepareMemoryJobFromDispatchJob;
pub const prepareKernelJobFromMemoryJob = execution_mod.prepareKernelJobFromMemoryJob;
pub const prepareTargetJobFromKernelJob = execution_mod.prepareTargetJobFromKernelJob;

pub const prepareBackendJobFromContractJob =
    prepared_mod.prepareBackendJobFromContractJob;
pub const prepareBackendJobFromContractPreparationResult =
    prepared_mod.prepareBackendJobFromContractPreparationResult;
pub const prepareBackendJobFromTensorPreparationResult =
    prepared_mod.prepareBackendJobFromTensorPreparationResult;
pub const prepareBackendJobFromDispatchPreparationResult =
    prepared_mod.prepareBackendJobFromDispatchPreparationResult;
pub const prepareBackendJobFromMemoryPreparationResult =
    prepared_mod.prepareBackendJobFromMemoryPreparationResult;
pub const prepareBackendJobFromKernelPreparationResult =
    prepared_mod.prepareBackendJobFromKernelPreparationResult;
pub const prepareBackendJobFromTargetPreparationResult =
    prepared_mod.prepareBackendJobFromTargetPreparationResult;

pub const prepareContractJobFromSemanticModuleWithRun =
    execution_mod.prepareContractJobFromSemanticModuleWithRun;
pub const prepareTensorJobFromContractJobWithRun =
    execution_mod.prepareTensorJobFromContractJobWithRun;
pub const prepareDispatchJobFromTensorJobWithRun =
    execution_mod.prepareDispatchJobFromTensorJobWithRun;
pub const prepareMemoryJobFromDispatchJobWithRun =
    execution_mod.prepareMemoryJobFromDispatchJobWithRun;
pub const prepareKernelJobFromMemoryJobWithRun =
    execution_mod.prepareKernelJobFromMemoryJobWithRun;
pub const prepareTargetJobFromKernelJobWithRun =
    execution_mod.prepareTargetJobFromKernelJobWithRun;

const testing = std.testing;

pub fn buildBackendPreparationContext(
    allocator: std.mem.Allocator,
    context_limits: ir.Context.Limits,
) !ir.Context {
    return try semantic.buildSemanticContext(allocator, context_limits);
}

fn expectProductStamp(
    stamp: choir.product.incremental.ProductStamp,
    name: []const u8,
    fingerprint: u64,
) !void {
    try testing.expectEqualStrings(name, stamp.name);
    try testing.expectEqual(fingerprint, stamp.fingerprint);
}

fn readSymbolName(func: *ir.Operation) ?[]const u8 {
    return ir.SymbolTable.getSymbolName(func);
}

fn hasFunctionNameSuffix(module_body: *ir.Block, suffix: []const u8) bool {
    var iter = module_body.operations.head;
    while (iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (std.mem.eql(u8, op.name.name, "func.func")) {
            if (readSymbolName(op)) |existing_name| {
                if (std.mem.endsWith(u8, existing_name, suffix)) return true;
            }
        }
        iter = op.next_op;
    }
    return false;
}

fn expectPreparedKernelPlan(
    allocator: std.mem.Allocator,
    choir_mod: *ir.Operation,
    ctx: *ir.Context,
    expected_kernel_count: usize,
) !void {
    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const schedule_plan = try schedule_planning.getSchedulePlanAnalysis(&pass_ctx, choir_mod);
    const outline_plan = try kernel_outlining.getKernelOutlinePlanAnalysis(&pass_ctx, choir_mod);
    const kernel_plan = try kernelization.getKernelizationAnalysis(&pass_ctx, choir_mod);
    const legal_plan = try backend_legalization.getBackendLegalizationAnalysis(
        &pass_ctx,
        choir_mod,
    );

    try testing.expectEqual(expected_kernel_count, schedule_plan.workItemCount());
    try testing.expectEqual(expected_kernel_count, outline_plan.kernelCount());
    try testing.expectEqual(expected_kernel_count, kernel_plan.kernelCount());
    try testing.expectEqual(expected_kernel_count, legal_plan.kernelCount());
    try testing.expect(legal_plan.isLegal());
}

fn expectTargetStagePipeline(pm: *const passes.PassManager) !void {
    try testing.expectEqual(target_pass_count, pm.root.pipeline.items.len);
    inline for (target_stages, 0..) |stage, index| {
        switch (pm.root.pipeline.items[index]) {
            .pass => |pass| try testing.expectEqualStrings(stage.name, pass.name),
            .nested => try testing.expect(false),
        }
    }
}

fn expectTensorStagePipeline(pm: *const passes.PassManager) !void {
    try testing.expectEqual(tensor_pass_count, pm.root.pipeline.items.len);
    inline for (tensor_stages, 0..) |stage, index| {
        switch (pm.root.pipeline.items[index]) {
            .pass => |pass| try testing.expectEqualStrings(stage.name, pass.name),
            .nested => try testing.expect(false),
        }
    }
}

fn expectDispatchStagePipeline(pm: *const passes.PassManager) !void {
    try testing.expectEqual(dispatch_pass_count, pm.root.pipeline.items.len);
    inline for (dispatch_stages, 0..) |stage, index| {
        switch (pm.root.pipeline.items[index]) {
            .pass => |pass| try testing.expectEqualStrings(stage.name, pass.name),
            .nested => try testing.expect(false),
        }
    }
}

fn expectMemoryStagePipeline(pm: *const passes.PassManager) !void {
    try testing.expectEqual(memory_pass_count, pm.root.pipeline.items.len);
    inline for (memory_stages, 0..) |stage, index| {
        switch (pm.root.pipeline.items[index]) {
            .pass => |pass| try testing.expectEqualStrings(stage.name, pass.name),
            .nested => try testing.expect(false),
        }
    }
}

fn expectKernelStagePipeline(pm: *const passes.PassManager) !void {
    try testing.expectEqual(kernel_pass_count, pm.root.pipeline.items.len);
    inline for (kernel_stages, 0..) |stage, index| {
        switch (pm.root.pipeline.items[index]) {
            .pass => |pass| try testing.expectEqualStrings(stage.name, pass.name),
            .nested => try testing.expect(false),
        }
    }
}

fn expectTargetStageText(text: []const u8) !void {
    var iter = std.mem.splitScalar(u8, text, ',');
    inline for (target_stages) |stage| {
        const name = iter.next() orelse return error.MissingTargetStage;
        try testing.expectEqualStrings(stage.name, name);
    }
    try testing.expect(iter.next() == null);
}

fn expectStagePlanText(
    allocator: std.mem.Allocator,
    comptime stages: anytype,
    pass_plan: passes.PassPlan,
) !void {
    const text = try pass_plan.formatAlloc(allocator);
    defer allocator.free(text);
    var iter = std.mem.splitScalar(u8, text, ',');
    inline for (stages) |stage| {
        const name = iter.next() orelse return error.MissingStage;
        try testing.expectEqualStrings(stage.name, name);
    }
    try testing.expect(iter.next() == null);
}

fn buildSemanticAddModule(
    allocator: std.mem.Allocator,
    name: []const u8,
    dims: []const i64,
) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const ty = try builder.tensor(.f32, dims);
    var fb = try builder.beginFunction(name, &.{ ty, ty }, &.{ty});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    return try builder.finish();
}

fn buildSemanticAddMulModule(
    allocator: std.mem.Allocator,
    name: []const u8,
    dims: []const i64,
) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const ty = try builder.tensor(.f32, dims);
    var fb = try builder.beginFunction(name, &.{ ty, ty, ty }, &.{ ty, ty });
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{ sum, product });
    try fb.finish();
    return try builder.finish();
}

fn prepareDispatchResultForContinuationTest(
    allocator: std.mem.Allocator,
    name: []const u8,
) !DispatchPreparationResult {
    const semantic_module = try buildSemanticAddMulModule(allocator, name, &.{4});
    var contract_result = try prepareContractJobFromSemanticModuleWithRun(
        allocator,
        semantic_module,
        .{},
    );
    var contract_owned = true;
    errdefer if (contract_owned) contract_result.deinit();

    contract_owned = false;
    var tensor_result = try prepareTensorJobFromContractJobWithRun(
        allocator,
        contract_result.module,
        .{},
    );
    var tensor_owned = true;
    errdefer if (tensor_owned) tensor_result.deinit();

    tensor_owned = false;
    return try prepareDispatchJobFromTensorJobWithRun(allocator, tensor_result.module, .{});
}

fn prepareMemoryResultForContinuationTest(
    allocator: std.mem.Allocator,
    name: []const u8,
) !MemoryPreparationResult {
    var dispatch_result = try prepareDispatchResultForContinuationTest(allocator, name);
    var dispatch_owned = true;
    errdefer if (dispatch_owned) dispatch_result.deinit();

    dispatch_owned = false;
    return try prepareMemoryJobFromDispatchJobWithRun(allocator, dispatch_result.module, .{});
}

fn prepareKernelResultForContinuationTest(
    allocator: std.mem.Allocator,
    name: []const u8,
) !KernelPreparationResult {
    var memory_result = try prepareMemoryResultForContinuationTest(allocator, name);
    var memory_owned = true;
    errdefer if (memory_owned) memory_result.deinit();

    memory_owned = false;
    return try prepareKernelJobFromMemoryJobWithRun(allocator, memory_result.module, .{});
}

fn prepareTargetResultForContinuationTest(
    allocator: std.mem.Allocator,
    name: []const u8,
) !TargetPreparationResult {
    var kernel_result = try prepareKernelResultForContinuationTest(allocator, name);
    var kernel_owned = true;
    errdefer if (kernel_owned) kernel_result.deinit();

    kernel_owned = false;
    return try prepareTargetJobFromKernelJobWithRun(allocator, kernel_result.module, .{});
}

fn expectPreparedRunFingerprints(prepared: *const BackendPreparedJob) !void {
    const target_module = try prepared.targetModule();
    const tensor_module = target_module.kernel_module.memory_module.dispatch_module.tensor_module;
    try testing.expectEqual(
        tensor_module.contract_module.fingerprint(),
        prepared.run.contract_fingerprint,
    );
    try testing.expectEqual(tensor_module.fingerprint(), prepared.run.tensor_fingerprint);
    try testing.expectEqual(target_module.fingerprint(), prepared.run.target_fingerprint);
    try testing.expect(prepared.run.dispatch_fingerprint != prepared.run.tensor_fingerprint);
    try testing.expect(prepared.run.memory_fingerprint != prepared.run.tensor_fingerprint);
    try testing.expect(prepared.run.kernel_fingerprint != prepared.run.tensor_fingerprint);
}

fn buildSemanticAddMulSubMaxModule(
    allocator: std.mem.Allocator,
    name: []const u8,
    dims: []const i64,
) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const ty = try builder.tensor(.f32, dims);
    var fb = try builder.beginFunction(name, &.{ ty, ty }, &.{ty});
    const rhs = fb.parameter(1);
    var current = try fb.add(fb.parameter(0), rhs);
    current = try fb.mul(current, rhs);
    current = try fb.sub(current, rhs);
    current = try fb.max(current, rhs);
    try fb.return_(&.{current});
    try fb.finish();
    return try builder.finish();
}

fn expectPreparedJobStamps(prepared: *const BackendPreparedJob) !void {
    const stamps = try prepared.productStamps();
    try expectProductStamp(
        stamps.semantic.?,
        semantic.product_name,
        prepared.run.semantic_fingerprint.?,
    );
    try expectProductStamp(
        stamps.contract,
        contract.product_name,
        prepared.run.contract_fingerprint,
    );
    try expectProductStamp(stamps.tensor, tensor.product_name, prepared.run.tensor_fingerprint);
    try expectProductStamp(
        stamps.dispatch,
        dispatch.product_name,
        prepared.run.dispatch_fingerprint,
    );
    try expectProductStamp(
        stamps.memory,
        memory_product.product_name,
        prepared.run.memory_fingerprint,
    );
    try expectProductStamp(
        stamps.kernel,
        kernel_product.product_name,
        prepared.run.kernel_fingerprint,
    );
    try expectProductStamp(
        stamps.target,
        target_product.product_name,
        prepared.run.target_fingerprint,
    );
}

fn expectPreparedJobState(prepared: *BackendPreparedJob, target: BackendTargetProfile) !void {
    const allocator = testing.allocator;
    const target_module = try prepared.targetModule();

    const read_target = target_profile.readBackendTargetProfile(prepared.choir_module) orelse
        return error.MissingTargetProfile;
    try testing.expectEqual(target.backend_kind, read_target.backend_kind);
    try testing.expectEqual(target.artifact_format, read_target.artifact_format);
    try testing.expectEqual(target.math_tier, read_target.math_tier);
    try testing.expectEqual(target.dtype_bits, read_target.dtype_bits);
    try testing.expect(prepared.choir_module == target_module.choir_module);
    try testing.expect(target_module.choir_module != target_module.kernel_module.choir_module);
    const kernel_stage_target = target_profile.readBackendTargetProfile(
        target_module.kernel_module.choir_module,
    ) orelse return error.MissingTargetProfile;
    try testing.expectEqual(target.artifact_format, kernel_stage_target.artifact_format);
    try testing.expectEqual(target.math_tier, kernel_stage_target.math_tier);
    try testing.expect(target_module.kernel_module.fingerprint() != 0);
    try testing.expectEqual(
        try choir.operationFingerprint(allocator, target_module.kernel_module.choir_module),
        target_module.kernel_module.fingerprint(),
    );
    try testing.expectEqual(target.backend_kind, prepared.run.target_profile.?.backend_kind);
    try testing.expectEqual(@as(u64, contract_pass_count), prepared.run.contract_stats.pass_runs);
    try testing.expectEqual(@as(u64, tensor_pass_count), prepared.run.tensor_stats.pass_runs);
    try testing.expectEqual(@as(u64, dispatch_pass_count), prepared.run.dispatch_stats.pass_runs);
    try testing.expectEqual(@as(u64, memory_pass_count), prepared.run.memory_stats.pass_runs);
    try testing.expectEqual(@as(u64, kernel_pass_count), prepared.run.kernel_stats.pass_runs);
    try testing.expectEqual(@as(u64, target_pass_count), prepared.run.target_stats.pass_runs);
    try testing.expect(prepared.run.contract_fingerprint != 0);
    try testing.expect(prepared.run.tensor_fingerprint != 0);
    try testing.expect(prepared.run.dispatch_fingerprint != 0);
    try testing.expect(prepared.run.memory_fingerprint != 0);
    try testing.expect(prepared.run.kernel_fingerprint != 0);
    try testing.expect(prepared.run.target_fingerprint != 0);
    try testing.expect(prepared.run.semantic_fingerprint != null);
    try expectPreparedJobStamps(prepared);
    try testing.expectEqual(
        try choir.operationFingerprint(allocator, prepared.choir_module),
        prepared.run.target_fingerprint,
    );
    try testing.expect(prepared.run.dispatch_stats.analysis_misses > 0);
    try testing.expect(prepared.run.memory_stats.analysis_misses > 0);
    try testing.expect(prepared.run.kernel_stats.analysis_misses > 0);
    try testing.expect(prepared.run.target_stats.analysis_misses > 0);
    try testing.expect(prepared.run.initial_choir_ops > 0);
    try testing.expect(prepared.run.final_choir_ops > 0);
    try testing.expect(prepared.ctx.isDialectLoaded("memref"));
    try testing.expect(prepared.ctx.isDialectLoaded("scf"));
}

fn expectPreparedJobProgram(prepared: *BackendPreparedJob, target: BackendTargetProfile) !void {
    const allocator = testing.allocator;
    const body = prepared.choir_module.getRegion(0).?.getEntryBlock().?;
    try testing.expect(ir.inspection.functionByNameInBlock(body, "prepared_product_add4") != null);
    try testing.expect(!hasFunctionNameSuffix(body, "lowered"));

    var pass_ctx = prepared.passContext();
    defer pass_ctx.deinit();
    const kernel_plan = try prepared.kernelizationProduct();
    const legal_plan = try backend_legalization.getBackendLegalizationAnalysis(
        &pass_ctx,
        prepared.choir_module,
    );

    try testing.expectEqual(@as(usize, 1), kernel_plan.kernelCount());
    try testing.expectEqual(@as(usize, 1), legal_plan.kernelCount());
    try testing.expect(legal_plan.isLegal());
    try testing.expectEqual(target.dtype_bits, legal_plan.target.?.dtype_bits);

    try testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
    const summary = try prepared.generatedKernelSummary(0);
    try testing.expect(summary.entry_name.len > 0);
    try testing.expectEqualStrings(kernel_plan.kernels.items[0].entry_name, summary.entry_name);
    try testing.expectEqual(kernel_plan.kernels.items[0].argument_count, summary.argument_count);
    try testing.expectEqual(
        kernel_plan.kernels.items[0].body_fingerprint,
        summary.body_fingerprint,
    );
    try testing.expectEqual(kernelization.GeneratedScheduleKind.flat, summary.schedule.kind);
    try testing.expect(summary.launch_geometry != null);
    const program = try prepared.generatedKernelProgram(0);
    try testing.expect(prepared.ctx != program.kernelModule().context);
    try ir.verifyOperation(program.kernelModule(), ir.verify.default_options);
    const launch = try program.launch();
    try testing.expectEqual(launch.block[0], summary.launch_geometry.?.threadgroup[0]);
    const work_summary = try prepared.generatedKernelSummaryForWork(summary.work_item_id);
    try testing.expectEqualStrings(summary.entry_name, work_summary.entry_name);
    try testing.expectEqual(summary.body_fingerprint, work_summary.body_fingerprint);
    const work_program = try prepared.generatedKernelProgramForWork(summary.work_item_id);
    const work_launch = try work_program.launch();
    try testing.expectEqual(launch.block[0], work_launch.block[0]);
    var summaries = try prepared.copyGeneratedKernelSummaries(allocator);
    defer summaries.deinit();
    try testing.expectEqual(@as(usize, 1), summaries.len());
    const copied_summary = try summaries.summaryForWork(summary.work_item_id);
    try testing.expectEqualStrings(summary.entry_name, copied_summary.entry_name);
    try testing.expectEqual(summary.body_fingerprint, copied_summary.body_fingerprint);
    try testing.expectError(error.InvalidIndex, prepared.generatedKernelSummary(1));
    try testing.expectError(
        error.MissingKernelization,
        prepared.generatedKernelSummaryForWork(std.math.maxInt(usize)),
    );
    try testing.expectError(
        error.MissingKernelization,
        summaries.summaryForWork(std.math.maxInt(usize)),
    );
}

fn expectPreparedJobDiagnostics(prepared: *BackendPreparedJob) !void {
    const target_module = try prepared.targetModule();
    prepared.run.semantic_fingerprint.? +%= 13;
    prepared.run.contract_fingerprint +%= 17;
    prepared.run.tensor_fingerprint +%= 19;
    prepared.run.dispatch_fingerprint +%= 23;
    prepared.run.memory_fingerprint +%= 29;
    prepared.run.kernel_fingerprint +%= 31;
    prepared.run.target_fingerprint +%= 37;

    const live_contract_fingerprint = target_module.kernel_module.memory_module.dispatch_module.tensor_module.contract_module.fingerprint();
    try testing.expect(live_contract_fingerprint != prepared.run.contract_fingerprint);
    try testing.expect(target_module.fingerprint() != prepared.run.target_fingerprint);

    try expectPreparedJobStamps(prepared);
}

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

test "target pipeline validates kernel candidates without static cloned IR" {
    const allocator = testing.allocator;

    const module = try buildSemanticAddModule(allocator, "pass_add4", &.{4});
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try addTargetPipeline(&pm);

    try testing.expectEqual(passes.PassResult.success, pm.run(choir_mod, ctx));
    try testing.expectEqual(@as(u64, target_pass_count), pm.stats.pass_runs);
    try testing.expect(pm.stats.analysis_misses > 0);

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    try testing.expect(ir.inspection.functionByNameInBlock(body, "pass_add4") != null);
    try testing.expect(!hasFunctionNameSuffix(body, "lowered"));
    try expectPreparedKernelPlan(allocator, choir_mod, ctx, 1);
}

test "prepareContractJobFromSemanticModule materializes normalized contract job" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();

    const ty = try builder.tensor(.f32, &.{1});
    var fb = try builder.beginFunction("contract_fold_add", &.{}, &.{ty});
    const one: [1]f32 = .{1};
    const two: [1]f32 = .{2};
    const lhs = try fb.constant(ty, std.mem.sliceAsBytes(one[0..]));
    const rhs = try fb.constant(ty, std.mem.sliceAsBytes(two[0..]));
    const sum = try fb.add(lhs, rhs);
    try fb.return_(&.{sum});
    try fb.finish();

    const semantic_module = try builder.finish();
    const contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        semantic_module,
        .{},
    );
    defer contract_module.deinit();

    try testing.expectEqualStrings(contract.product_name, accy_choir.contract_product_name);
    try contract_module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(
        contract_module.choir_module,
        dialect_mod.AccyDialect.AddOp.operation_name,
    ));
}

test "prepareTensorJobFromContractJob materializes tensor job" {
    const allocator = testing.allocator;

    const semantic_module = try buildSemanticAddMulModule(
        allocator,
        "tensor_product_add_mul",
        &.{4},
    );
    const contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        semantic_module,
        .{},
    );
    const tensor_module = try prepareTensorJobFromContractJob(allocator, contract_module, .{});
    defer tensor_module.deinit();

    try testing.expectEqualStrings(tensor.product_name, accy_choir.tensor_product_name);
    try tensor_module.verify();
}

test "prepareDispatchJobFromTensorJob materializes dispatch job" {
    const allocator = testing.allocator;

    const semantic_module = try buildSemanticAddMulModule(
        allocator,
        "dispatch_product_add_mul",
        &.{4},
    );
    const contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        semantic_module,
        .{},
    );
    const tensor_module = try prepareTensorJobFromContractJob(allocator, contract_module, .{});
    const dispatch_module = try prepareDispatchJobFromTensorJob(allocator, tensor_module, .{});
    defer dispatch_module.deinit();

    try testing.expectEqualStrings(dispatch.product_name, accy_choir.dispatch_product_name);
    try dispatch_module.verify();
    try testing.expect(dispatch_module.tensor_module.analysis_cache.entries.count() > 0);
    var pass_ctx = dispatch_module.passContext();
    defer pass_ctx.deinit();
    const plan = try schedule_planning.getSchedulePlanAnalysis(&pass_ctx, pass_ctx.op);
    try testing.expectEqual(@as(usize, 2), plan.workItemCount());
}

test "prepareDispatchJobFromTensorJob fingerprints dispatch analysis product" {
    const allocator = testing.allocator;

    const first_semantic_module = try buildSemanticAddMulModule(
        allocator,
        "dispatch_fingerprint_first",
        &.{4},
    );
    const first_contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        first_semantic_module,
        .{},
    );
    const first_tensor_module = try prepareTensorJobFromContractJob(
        allocator,
        first_contract_module,
        .{},
    );
    var first_dispatch = try prepareDispatchJobFromTensorJobWithRun(
        allocator,
        first_tensor_module,
        .{},
    );
    defer first_dispatch.deinit();

    const second_semantic_module = try buildSemanticAddMulModule(
        allocator,
        "dispatch_fingerprint_second",
        &.{4},
    );
    const second_contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        second_semantic_module,
        .{},
    );
    const second_tensor_module = try prepareTensorJobFromContractJob(
        allocator,
        second_contract_module,
        .{},
    );
    var second_dispatch = try prepareDispatchJobFromTensorJobWithRun(
        allocator,
        second_tensor_module,
        .{},
    );
    defer second_dispatch.deinit();

    const changed_semantic_module = try buildSemanticAddMulSubMaxModule(
        allocator,
        "dispatch_fingerprint_changed",
        &.{4},
    );
    const changed_contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        changed_semantic_module,
        .{},
    );
    const changed_tensor_module = try prepareTensorJobFromContractJob(
        allocator,
        changed_contract_module,
        .{},
    );
    var changed_dispatch = try prepareDispatchJobFromTensorJobWithRun(
        allocator,
        changed_tensor_module,
        .{},
    );
    defer changed_dispatch.deinit();

    try testing.expectEqual(first_dispatch.plan_fingerprint, second_dispatch.plan_fingerprint);
    try testing.expect(first_dispatch.plan_fingerprint != changed_dispatch.plan_fingerprint);
}

test "prepareMemoryJobFromDispatchJob materializes memory job" {
    const allocator = testing.allocator;

    const semantic_module = try buildSemanticAddMulModule(
        allocator,
        "memory_product_add_mul",
        &.{4},
    );
    const contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        semantic_module,
        .{},
    );
    const tensor_module = try prepareTensorJobFromContractJob(allocator, contract_module, .{});
    const dispatch_module = try prepareDispatchJobFromTensorJob(allocator, tensor_module, .{});
    const memory_module = try prepareMemoryJobFromDispatchJob(allocator, dispatch_module, .{});
    defer memory_module.deinit();

    try testing.expectEqualStrings(memory_product.product_name, accy_choir.memory_product_name);
    try memory_module.verify();
    try testing.expect(
        memory_module.dispatch_module.tensor_module.analysis_cache.entries.count() > 0,
    );
    var pass_ctx = memory_module.passContext();
    defer pass_ctx.deinit();
    const buffers = @import("bufferization/root.zig");
    const plan = try buffers.getBufferPlanAnalysis(&pass_ctx, pass_ctx.op);
    try testing.expectEqual(@as(usize, 5), plan.slotCount());
}

test "prepareMemoryJobFromDispatchJob fingerprints memory analysis product" {
    const allocator = testing.allocator;

    const first_semantic_module = try buildSemanticAddMulModule(
        allocator,
        "memory_fingerprint_first",
        &.{4},
    );
    const first_contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        first_semantic_module,
        .{},
    );
    const first_tensor_module = try prepareTensorJobFromContractJob(
        allocator,
        first_contract_module,
        .{},
    );
    const first_dispatch_module = try prepareDispatchJobFromTensorJob(
        allocator,
        first_tensor_module,
        .{},
    );
    var first_memory = try prepareMemoryJobFromDispatchJobWithRun(
        allocator,
        first_dispatch_module,
        .{},
    );
    defer first_memory.deinit();

    const second_semantic_module = try buildSemanticAddMulModule(
        allocator,
        "memory_fingerprint_second",
        &.{4},
    );
    const second_contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        second_semantic_module,
        .{},
    );
    const second_tensor_module = try prepareTensorJobFromContractJob(
        allocator,
        second_contract_module,
        .{},
    );
    const second_dispatch_module = try prepareDispatchJobFromTensorJob(
        allocator,
        second_tensor_module,
        .{},
    );
    var second_memory = try prepareMemoryJobFromDispatchJobWithRun(
        allocator,
        second_dispatch_module,
        .{},
    );
    defer second_memory.deinit();

    const changed_semantic_module = try buildSemanticAddMulSubMaxModule(
        allocator,
        "memory_fingerprint_changed",
        &.{4},
    );
    const changed_contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        changed_semantic_module,
        .{},
    );
    const changed_tensor_module = try prepareTensorJobFromContractJob(
        allocator,
        changed_contract_module,
        .{},
    );
    const changed_dispatch_module = try prepareDispatchJobFromTensorJob(
        allocator,
        changed_tensor_module,
        .{},
    );
    var changed_memory = try prepareMemoryJobFromDispatchJobWithRun(
        allocator,
        changed_dispatch_module,
        .{},
    );
    defer changed_memory.deinit();

    try testing.expectEqual(first_memory.plan_fingerprint, second_memory.plan_fingerprint);
    try testing.expect(first_memory.plan_fingerprint != changed_memory.plan_fingerprint);
}

test "prepareKernelJobFromMemoryJob materializes kernel job" {
    const allocator = testing.allocator;

    const semantic_module = try buildSemanticAddMulModule(
        allocator,
        "kernel_product_add_mul",
        &.{4},
    );
    const contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        semantic_module,
        .{},
    );
    const tensor_module = try prepareTensorJobFromContractJob(allocator, contract_module, .{});
    const dispatch_module = try prepareDispatchJobFromTensorJob(allocator, tensor_module, .{});
    const memory_module = try prepareMemoryJobFromDispatchJob(allocator, dispatch_module, .{});
    const kernel_module = try prepareKernelJobFromMemoryJob(allocator, memory_module, .{});
    defer kernel_module.deinit();

    try testing.expectEqualStrings(kernel_product.product_name, accy_choir.kernel_product_name);
    try kernel_module.verify();
    try testing.expect(
        kernel_module.memory_module.dispatch_module.tensor_module.analysis_cache.entries.count() > 0,
    );

    var pass_ctx = kernel_module.passContext();
    defer pass_ctx.deinit();
    const kernel_plan = try kernelization.getKernelizationAnalysis(
        &pass_ctx,
        kernel_module.choir_module,
    );
    try testing.expectEqual(@as(usize, 2), kernel_plan.kernelCount());
}

test "prepareKernelJobFromMemoryJob fingerprints kernel analysis product" {
    const allocator = testing.allocator;

    const first_semantic_module = try buildSemanticAddMulModule(
        allocator,
        "kernel_fingerprint_first",
        &.{4},
    );
    const first_contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        first_semantic_module,
        .{},
    );
    const first_tensor_module = try prepareTensorJobFromContractJob(
        allocator,
        first_contract_module,
        .{},
    );
    const first_dispatch_module = try prepareDispatchJobFromTensorJob(
        allocator,
        first_tensor_module,
        .{},
    );
    const first_memory_module = try prepareMemoryJobFromDispatchJob(
        allocator,
        first_dispatch_module,
        .{},
    );
    var first_kernel = try prepareKernelJobFromMemoryJobWithRun(
        allocator,
        first_memory_module,
        .{},
    );
    defer first_kernel.deinit();

    const second_semantic_module = try buildSemanticAddMulModule(
        allocator,
        "kernel_fingerprint_second",
        &.{4},
    );
    const second_contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        second_semantic_module,
        .{},
    );
    const second_tensor_module = try prepareTensorJobFromContractJob(
        allocator,
        second_contract_module,
        .{},
    );
    const second_dispatch_module = try prepareDispatchJobFromTensorJob(
        allocator,
        second_tensor_module,
        .{},
    );
    const second_memory_module = try prepareMemoryJobFromDispatchJob(
        allocator,
        second_dispatch_module,
        .{},
    );
    var second_kernel = try prepareKernelJobFromMemoryJobWithRun(
        allocator,
        second_memory_module,
        .{},
    );
    defer second_kernel.deinit();

    const changed_semantic_module = try buildSemanticAddMulSubMaxModule(
        allocator,
        "kernel_fingerprint_changed",
        &.{4},
    );
    const changed_contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        changed_semantic_module,
        .{},
    );
    const changed_tensor_module = try prepareTensorJobFromContractJob(
        allocator,
        changed_contract_module,
        .{},
    );
    const changed_dispatch_module = try prepareDispatchJobFromTensorJob(
        allocator,
        changed_tensor_module,
        .{},
    );
    const changed_memory_module = try prepareMemoryJobFromDispatchJob(
        allocator,
        changed_dispatch_module,
        .{},
    );
    var changed_kernel = try prepareKernelJobFromMemoryJobWithRun(
        allocator,
        changed_memory_module,
        .{},
    );
    defer changed_kernel.deinit();

    try testing.expectEqual(first_kernel.plan_fingerprint, second_kernel.plan_fingerprint);
    try testing.expect(first_kernel.plan_fingerprint != changed_kernel.plan_fingerprint);
}

test "kernel preparation lowers fused elementwise benchmark chain" {
    const allocator = testing.allocator;

    const semantic_module = try buildSemanticAddMulSubMaxModule(
        allocator,
        "kernel_product_add_mul_sub_max",
        &.{16},
    );
    const contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        semantic_module,
        .{},
    );
    const tensor_module = try prepareTensorJobFromContractJob(allocator, contract_module, .{});
    const dispatch_module = try prepareDispatchJobFromTensorJob(allocator, tensor_module, .{});
    const memory_module = try prepareMemoryJobFromDispatchJob(allocator, dispatch_module, .{});
    const kernel_module = try prepareKernelJobFromMemoryJob(allocator, memory_module, .{});
    defer kernel_module.deinit();

    var pass_ctx = kernel_module.passContext();
    defer pass_ctx.deinit();
    const kernel_plan = try kernelization.getKernelizationAnalysis(
        &pass_ctx,
        kernel_module.choir_module,
    );
    try testing.expectEqual(@as(usize, 1), kernel_plan.kernelCount());
    const kernel = kernel_plan.kernels.items[0];
    try testing.expect(std.mem.indexOf(u8, kernel.entry_name, "add") != null);
    try testing.expect(std.mem.indexOf(u8, kernel.entry_name, "mul") != null);
    try testing.expect(std.mem.indexOf(u8, kernel.entry_name, "sub") != null);
    try testing.expect(std.mem.indexOf(u8, kernel.entry_name, "max") != null);
}

test "kernel preparation handles einsum operand-local reductions" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 16, 16 });
    const rhs_ty = try builder.tensor(.f32, &.{ 16, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 16, 16 });
    var fb = try builder.beginFunction(
        "kernel_product_einsum_local_reduction",
        &.{ lhs_ty, rhs_ty },
        &.{out_ty},
    );
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "ab,cd->ac");
    try fb.return_(&.{out});
    try fb.finish();
    const semantic_module = try builder.finish();

    const contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        semantic_module,
        .{},
    );
    const tensor_module = try prepareTensorJobFromContractJob(allocator, contract_module, .{});
    const dispatch_module = try prepareDispatchJobFromTensorJob(allocator, tensor_module, .{});
    const memory_module = try prepareMemoryJobFromDispatchJob(allocator, dispatch_module, .{});
    const kernel_module = try prepareKernelJobFromMemoryJob(allocator, memory_module, .{});
    defer kernel_module.deinit();

    try kernel_module.verify();
    var pass_ctx = kernel_module.passContext();
    defer pass_ctx.deinit();
    const kernel_plan = try kernelization.getKernelizationAnalysis(
        &pass_ctx,
        kernel_module.choir_module,
    );
    try testing.expectEqual(@as(usize, 3), kernel_plan.kernelCount());
}

test "kernel preparation handles three operand einsum contractions" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const q_ty = try builder.tensor(.f32, &.{ 2, 16, 16 });
    const k_ty = try builder.tensor(.f32, &.{ 2, 16, 16 });
    const v_ty = try builder.tensor(.f32, &.{ 2, 16, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 2, 16, 16 });
    var fb = try builder.beginFunction(
        "kernel_product_einsum_three_operand",
        &.{ q_ty, k_ty, v_ty },
        &.{out_ty},
    );
    const out = try fb.einsum(
        &.{ fb.parameter(0), fb.parameter(1), fb.parameter(2) },
        out_ty,
        "bqd,bkd,bkv->bqv",
    );
    try fb.return_(&.{out});
    try fb.finish();
    const semantic_module = try builder.finish();

    const contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        semantic_module,
        .{},
    );
    const tensor_module = try prepareTensorJobFromContractJob(allocator, contract_module, .{});
    const dispatch_module = try prepareDispatchJobFromTensorJob(allocator, tensor_module, .{});
    const memory_module = try prepareMemoryJobFromDispatchJob(allocator, dispatch_module, .{});
    const kernel_module = try prepareKernelJobFromMemoryJob(allocator, memory_module, .{});
    defer kernel_module.deinit();

    try kernel_module.verify();
    var pass_ctx = kernel_module.passContext();
    defer pass_ctx.deinit();
    const kernel_plan = try kernelization.getKernelizationAnalysis(
        &pass_ctx,
        kernel_module.choir_module,
    );
    try testing.expect(kernel_plan.kernelCount() > 0);
}

test "prepareTargetJobFromKernelJob materializes target job" {
    const allocator = testing.allocator;

    const semantic_module = try buildSemanticAddMulModule(
        allocator,
        "target_product_add_mul",
        &.{4},
    );
    const contract_module = try prepareContractJobFromSemanticModule(
        allocator,
        semantic_module,
        .{},
    );
    const tensor_module = try prepareTensorJobFromContractJob(allocator, contract_module, .{});
    const dispatch_module = try prepareDispatchJobFromTensorJob(allocator, tensor_module, .{});
    const memory_module = try prepareMemoryJobFromDispatchJob(allocator, dispatch_module, .{});
    const kernel_module = try prepareKernelJobFromMemoryJob(allocator, memory_module, .{});
    const target_module = try prepareTargetJobFromKernelJob(allocator, kernel_module, .{});
    defer target_module.deinit();

    try target_module.verify();
    try testing.expect(target_module.choir_module != target_module.kernel_module.choir_module);
    try testing.expect(
        target_module.kernel_module.memory_module.dispatch_module.tensor_module.analysis_cache.entries.count() > 0,
    );
    try testing.expect(target_module.analysis_cache.entries.count() > 0);
    try testing.expectEqual(@as(usize, 2), target_module.kernelizationProduct().kernelCount());

    var pass_ctx = target_module.passContext();
    defer pass_ctx.deinit();
    const legal_plan = try backend_legalization.getBackendLegalizationAnalysis(
        &pass_ctx,
        target_module.choir_module,
    );
    try testing.expectEqual(@as(usize, 2), legal_plan.kernelCount());
    try testing.expect(legal_plan.isLegal());
}

test "prepareBackendJobFromDispatchPreparationResult continues prepared pipeline" {
    const allocator = testing.allocator;

    var dispatch_result = try prepareDispatchResultForContinuationTest(
        allocator,
        "dispatch_continuation_add_mul",
    );
    var dispatch_owned = true;
    errdefer if (dispatch_owned) dispatch_result.deinit();

    const dispatch_ns = dispatch_result.elapsed_ns;
    const dispatch_stats = dispatch_result.stats;
    const dispatch_fingerprint = dispatch_result.plan_fingerprint;
    dispatch_owned = false;
    var prepared = try prepareBackendJobFromDispatchPreparationResult(
        allocator,
        dispatch_result,
        .{},
        11,
        .{ .pass_runs = 101, .analysis_hits = 102 },
        13,
        .{ .pass_runs = 103, .analysis_misses = 104 },
        17,
        null,
        0,
    );
    defer prepared.deinit();

    try testing.expectEqual(@as(u64, 11), prepared.run.contract_ns);
    try testing.expectEqual(@as(u64, 13), prepared.run.tensor_ns);
    try testing.expectEqual(dispatch_ns, prepared.run.dispatch_ns);
    try testing.expectEqual(@as(u64, 101), prepared.run.contract_stats.pass_runs);
    try testing.expectEqual(@as(u64, 102), prepared.run.contract_stats.analysis_hits);
    try testing.expectEqual(@as(u64, 103), prepared.run.tensor_stats.pass_runs);
    try testing.expectEqual(@as(u64, 104), prepared.run.tensor_stats.analysis_misses);
    try testing.expectEqual(dispatch_stats.pass_runs, prepared.run.dispatch_stats.pass_runs);
    try testing.expectEqual(
        dispatch_stats.analysis_misses,
        prepared.run.dispatch_stats.analysis_misses,
    );
    try testing.expectEqual(@as(u64, memory_pass_count), prepared.run.memory_stats.pass_runs);
    try testing.expectEqual(@as(u64, kernel_pass_count), prepared.run.kernel_stats.pass_runs);
    try testing.expectEqual(@as(u64, target_pass_count), prepared.run.target_stats.pass_runs);
    try testing.expectEqual(@as(u64, 17), prepared.run.initial_choir_ops);
    try testing.expectEqual(dispatch_fingerprint, prepared.run.dispatch_fingerprint);
    try expectPreparedRunFingerprints(&prepared);
    try testing.expectEqual(@as(usize, 2), try prepared.generatedKernelCount());
}

test "prepareBackendJobFromMemoryPreparationResult continues prepared pipeline" {
    const allocator = testing.allocator;

    var memory_result = try prepareMemoryResultForContinuationTest(
        allocator,
        "memory_continuation_add_mul",
    );
    var memory_owned = true;
    errdefer if (memory_owned) memory_result.deinit();

    const memory_ns = memory_result.elapsed_ns;
    const memory_stats = memory_result.stats;
    const memory_fingerprint = memory_result.plan_fingerprint;
    memory_owned = false;
    var prepared = try prepareBackendJobFromMemoryPreparationResult(
        allocator,
        memory_result,
        .{},
        19,
        .{ .pass_runs = 107 },
        23,
        .{ .pass_runs = 109 },
        29,
        .{ .pass_runs = 113, .analysis_hits = 114 },
        127,
        31,
        null,
        0,
    );
    defer prepared.deinit();

    try testing.expectEqual(@as(u64, 19), prepared.run.contract_ns);
    try testing.expectEqual(@as(u64, 23), prepared.run.tensor_ns);
    try testing.expectEqual(@as(u64, 29), prepared.run.dispatch_ns);
    try testing.expectEqual(memory_ns, prepared.run.memory_ns);
    try testing.expectEqual(@as(u64, 107), prepared.run.contract_stats.pass_runs);
    try testing.expectEqual(@as(u64, 109), prepared.run.tensor_stats.pass_runs);
    try testing.expectEqual(@as(u64, 113), prepared.run.dispatch_stats.pass_runs);
    try testing.expectEqual(@as(u64, 114), prepared.run.dispatch_stats.analysis_hits);
    try testing.expectEqual(memory_stats.pass_runs, prepared.run.memory_stats.pass_runs);
    try testing.expectEqual(
        memory_stats.analysis_misses,
        prepared.run.memory_stats.analysis_misses,
    );
    try testing.expectEqual(@as(u64, kernel_pass_count), prepared.run.kernel_stats.pass_runs);
    try testing.expectEqual(@as(u64, target_pass_count), prepared.run.target_stats.pass_runs);
    try testing.expectEqual(@as(u64, 31), prepared.run.initial_choir_ops);
    try testing.expectEqual(@as(u64, 127), prepared.run.dispatch_fingerprint);
    try testing.expectEqual(memory_fingerprint, prepared.run.memory_fingerprint);
    try expectPreparedRunFingerprints(&prepared);
    try testing.expectEqual(@as(usize, 2), try prepared.generatedKernelCount());
}

test "prepareBackendJobFromKernelPreparationResult continues prepared pipeline" {
    const allocator = testing.allocator;

    var kernel_result = try prepareKernelResultForContinuationTest(
        allocator,
        "kernel_continuation_add_mul",
    );
    var kernel_owned = true;
    errdefer if (kernel_owned) kernel_result.deinit();

    const kernel_ns = kernel_result.elapsed_ns;
    const kernel_stats = kernel_result.stats;
    const kernel_fingerprint = kernel_result.plan_fingerprint;
    kernel_owned = false;
    var prepared = try prepareBackendJobFromKernelPreparationResult(
        allocator,
        kernel_result,
        .{},
        37,
        .{ .pass_runs = 127 },
        41,
        .{ .pass_runs = 131 },
        43,
        .{ .pass_runs = 137 },
        149,
        47,
        .{ .pass_runs = 139, .analysis_misses = 140 },
        151,
        53,
        null,
        0,
    );
    defer prepared.deinit();

    try testing.expectEqual(@as(u64, 37), prepared.run.contract_ns);
    try testing.expectEqual(@as(u64, 41), prepared.run.tensor_ns);
    try testing.expectEqual(@as(u64, 43), prepared.run.dispatch_ns);
    try testing.expectEqual(@as(u64, 47), prepared.run.memory_ns);
    try testing.expectEqual(kernel_ns, prepared.run.kernel_ns);
    try testing.expectEqual(@as(u64, 139), prepared.run.memory_stats.pass_runs);
    try testing.expectEqual(@as(u64, 140), prepared.run.memory_stats.analysis_misses);
    try testing.expectEqual(kernel_stats.pass_runs, prepared.run.kernel_stats.pass_runs);
    try testing.expectEqual(
        kernel_stats.analysis_misses,
        prepared.run.kernel_stats.analysis_misses,
    );
    try testing.expectEqual(@as(u64, target_pass_count), prepared.run.target_stats.pass_runs);
    try testing.expectEqual(@as(u64, 53), prepared.run.initial_choir_ops);
    try testing.expectEqual(@as(u64, 149), prepared.run.dispatch_fingerprint);
    try testing.expectEqual(@as(u64, 151), prepared.run.memory_fingerprint);
    try testing.expectEqual(kernel_fingerprint, prepared.run.kernel_fingerprint);
    try expectPreparedRunFingerprints(&prepared);
    try testing.expectEqual(@as(usize, 2), try prepared.generatedKernelCount());
}

test "prepareBackendJobFromTargetPreparationResult owns prepared product" {
    const allocator = testing.allocator;

    var target_result = try prepareTargetResultForContinuationTest(
        allocator,
        "target_continuation_add_mul",
    );
    var target_owned = true;
    errdefer if (target_owned) target_result.deinit();

    const target_ns = target_result.elapsed_ns;
    const target_stats = target_result.stats;
    const target_fingerprint = target_result.module.fingerprint();
    target_owned = false;
    var prepared = try prepareBackendJobFromTargetPreparationResult(
        allocator,
        target_result,
        .{},
        59,
        .{ .pass_runs = 149 },
        61,
        .{ .pass_runs = 151 },
        67,
        .{ .pass_runs = 157 },
        173,
        71,
        .{ .pass_runs = 163 },
        179,
        73,
        .{ .pass_runs = 167, .analysis_hits = 168 },
        181,
        79,
        null,
        0,
    );
    defer prepared.deinit();

    try testing.expectEqual(@as(u64, 59), prepared.run.contract_ns);
    try testing.expectEqual(@as(u64, 61), prepared.run.tensor_ns);
    try testing.expectEqual(@as(u64, 67), prepared.run.dispatch_ns);
    try testing.expectEqual(@as(u64, 71), prepared.run.memory_ns);
    try testing.expectEqual(@as(u64, 73), prepared.run.kernel_ns);
    try testing.expectEqual(target_ns, prepared.run.target_ns);
    try testing.expectEqual(@as(u64, 167), prepared.run.kernel_stats.pass_runs);
    try testing.expectEqual(@as(u64, 168), prepared.run.kernel_stats.analysis_hits);
    try testing.expectEqual(target_stats.pass_runs, prepared.run.target_stats.pass_runs);
    try testing.expectEqual(
        target_stats.analysis_misses,
        prepared.run.target_stats.analysis_misses,
    );
    try testing.expectEqual(@as(u64, 79), prepared.run.initial_choir_ops);
    try testing.expectEqual(@as(u64, 173), prepared.run.dispatch_fingerprint);
    try testing.expectEqual(@as(u64, 179), prepared.run.memory_fingerprint);
    try testing.expectEqual(@as(u64, 181), prepared.run.kernel_fingerprint);
    try testing.expectEqual(target_fingerprint, prepared.run.target_fingerprint);
    try expectPreparedRunFingerprints(&prepared);
    try testing.expectEqual(@as(usize, 2), try prepared.generatedKernelCount());
}

test "prepareBackendJobFromSemanticModule owns its transient pipeline and diagnostic summaries" {
    const allocator = testing.allocator;

    const target = try BackendTargetProfile.init(.{
        .identity = .{
            .backend = .cuda,
            .family = .nvidia_cuda,
        },
        .dtypes = gpu.DTypeSet.init(&.{ .f32, .i32 }),
        .artifact_formats = gpu.ArtifactFormatSet.init(&.{.cuda_ptx}),
    }, .cuda, .cuda_ptx);

    const module = try buildSemanticAddModule(allocator, "prepared_product_add4", &.{4});
    var prepared = try prepareBackendJobFromSemanticModule(
        allocator,
        module,
        .{ .target_profile = target },
    );
    defer prepared.deinit();
    try expectPreparedJobState(&prepared, target);
    try expectPreparedJobProgram(&prepared, target);
    try expectPreparedJobDiagnostics(&prepared);
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

test "backend preparation target profile constrains backend legalization dtypes" {
    const allocator = testing.allocator;

    const target = try BackendTargetProfile.init(.{
        .identity = .{
            .backend = .vulkan,
            .family = .vulkan,
        },
        .dtypes = gpu.DTypeSet.init(&.{.i32}),
        .artifact_formats = gpu.ArtifactFormatSet.init(&.{.vulkan_spirv}),
    }, .vulkan, .vulkan_spirv);

    const module = try buildSemanticAddModule(allocator, "target_profile_rejects_f32", &.{4});
    var prepared = try prepareBackendJobFromSemanticModule(
        allocator,
        module,
        .{ .target_profile = target },
    );
    defer prepared.deinit();

    var pass_ctx = prepared.passContext();
    defer pass_ctx.deinit();
    const legal_plan = try backend_legalization.getBackendLegalizationAnalysis(
        &pass_ctx,
        prepared.choir_module,
    );
    const status = legal_plan.firstIllegalStatus() orelse return error.MissingIllegalKernel;

    try testing.expect(!legal_plan.isLegal());
    try testing.expect(!legal_plan.hasPipelineFailure());
    try testing.expectEqual(backend_legalization.BackendKernelStatus.unsupported_dtype, status);
    try testing.expectEqual(
        error.CapabilityMismatch,
        backend_legalization.backendKernelStatusError(status),
    );
}

test "backend preparation pipelines register through Choir extensions" {
    const allocator = testing.allocator;

    var ctx = try buildBackendPreparationContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, accy_choir_package_extension);

    var pipeline_registry = passes.PipelineRegistry.init(allocator);
    defer pipeline_registry.deinit();
    try extension_registry.registerPipelinesTo(&pipeline_registry);
    try testing.expect(pipeline_registry.lookup(contract_pipeline_name) != null);
    try testing.expect(pipeline_registry.lookup(tensor_pipeline_name) != null);
    try testing.expect(pipeline_registry.lookup(dispatch_pipeline_name) != null);
    try testing.expect(pipeline_registry.lookup(memory_pipeline_name) != null);
    try testing.expect(pipeline_registry.lookup(kernel_pipeline_name) != null);
    try testing.expect(pipeline_registry.lookup(target_pipeline_name) != null);

    var contract_pm = passes.PassManager.init(allocator);
    defer contract_pm.deinit();
    try pipeline_registry.addPipelineTo(contract_pipeline_name, &contract_pm);
    try testing.expectEqual(contract_pass_count, contract_pm.root.pipeline.items.len);

    var tensor_pm = passes.PassManager.init(allocator);
    defer tensor_pm.deinit();
    try pipeline_registry.addPipelineTo(tensor_pipeline_name, &tensor_pm);
    try expectTensorStagePipeline(&tensor_pm);

    var dispatch_pm = passes.PassManager.init(allocator);
    defer dispatch_pm.deinit();
    try pipeline_registry.addPipelineTo(dispatch_pipeline_name, &dispatch_pm);
    try expectDispatchStagePipeline(&dispatch_pm);

    var memory_pm = passes.PassManager.init(allocator);
    defer memory_pm.deinit();
    try pipeline_registry.addPipelineTo(memory_pipeline_name, &memory_pm);
    try expectMemoryStagePipeline(&memory_pm);

    var kernel_pm = passes.PassManager.init(allocator);
    defer kernel_pm.deinit();
    try pipeline_registry.addPipelineTo(kernel_pipeline_name, &kernel_pm);
    try expectKernelStagePipeline(&kernel_pm);

    var target_pm = passes.PassManager.init(allocator);
    defer target_pm.deinit();
    try pipeline_registry.addPipelineTo(target_pipeline_name, &target_pm);
    try expectTargetStagePipeline(&target_pm);
}

test "individual Accy Choir passes register through Choir extensions" {
    const allocator = testing.allocator;

    var ctx = try buildBackendPreparationContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, accy_choir_package_extension);

    var pass_registry = passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    try testing.expectEqual(
        @as(usize, accy_choir_pass_registrations.len),
        pass_registry.passes.items.len,
    );
    inline for (accy_choir_pass_registrations) |registration| {
        try testing.expect(pass_registry.lookupPass(registration.name) != null);
    }

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try passes.parsePassPipeline(
        &pass_registry,
        canonicalization_pass_name ++ "," ++ saturation_pass_name,
        &pm,
    );
    try testing.expectEqual(@as(usize, 2), pm.root.pipeline.items.len);

    const text = try passes.formatPassManagerPipelineAlloc(allocator, &pm);
    defer allocator.free(text);
    try testing.expectEqualStrings(canonicalization_pass_name ++ "," ++ saturation_pass_name, text);
}

test "backend preparation stage table defines registries and profiling products" {
    try testing.expectEqual(contract_stages.len, contract_pass_count);
    try testing.expectEqual(tensor_stages.len, tensor_pass_count);
    try testing.expectEqual(dispatch_stages.len, dispatch_pass_count);
    try testing.expectEqual(memory_stages.len, memory_pass_count);
    try testing.expectEqual(kernel_stages.len, kernel_pass_count);
    try testing.expectEqual(target_stages.len, target_pass_count);
    try testing.expectEqual(contract_stages.len + tensor_stages.len + dispatch_stages.len +
        memory_stages.len +
        kernel_stages.len + target_stages.len, accy_choir_pass_registrations.len);
    try testing.expectEqualStrings(
        kernelization.kernelization_analysis_descriptor.name,
        kernel_stages[1].analysis_name.?,
    );
    try testing.expectEqual(contract_stages.len, contract_pass_plan.steps.len);
    try testing.expectEqual(tensor_stages.len, tensor_pass_plan.steps.len);
    try testing.expectEqual(dispatch_stages.len, dispatch_pass_plan.steps.len);
    try testing.expectEqual(memory_stages.len, memory_pass_plan.steps.len);
    try testing.expectEqual(kernel_stages.len, kernel_pass_plan.steps.len);
    try testing.expectEqual(target_stages.len, target_pass_plan.steps.len);

    var contract_analysis_index: usize = 0;
    inline for (contract_stages, 0..) |stage, index| {
        try testing.expectEqualStrings(stage.name, contractPassName(index));
        try testing.expectEqualStrings(stage.name, accy_choir_pass_registrations[index].name);
        try testing.expectEqualStrings(
            stage.description,
            accy_choir_pass_registrations[index].description,
        );
        try testing.expectEqualStrings(
            stage.pass.name,
            accy_choir_pass_registrations[index].pass.name,
        );

        if (stage.analysis_name) |name| {
            try testing.expectEqualStrings(name, contractAnalysisName(contract_analysis_index));
            contract_analysis_index += 1;
        }
    }

    var tensor_analysis_index: usize = 0;
    inline for (tensor_stages, 0..) |stage, index| {
        const registration_index = contract_stages.len + index;
        try testing.expectEqualStrings(stage.name, tensorPassName(index));
        try testing.expectEqualStrings(
            stage.name,
            accy_choir_pass_registrations[registration_index].name,
        );
        try testing.expectEqualStrings(
            stage.description,
            accy_choir_pass_registrations[registration_index].description,
        );
        try testing.expectEqualStrings(
            stage.pass.name,
            accy_choir_pass_registrations[registration_index].pass.name,
        );
        try testing.expectEqual(
            stage.options.len,
            accy_choir_pass_registrations[registration_index].options.len,
        );
        try testing.expectEqual(
            stage.build_with_options != null,
            accy_choir_pass_registrations[registration_index].build_with_options != null,
        );

        if (stage.analysis_name) |name| {
            try testing.expectEqualStrings(name, tensorAnalysisName(tensor_analysis_index));
            tensor_analysis_index += 1;
        }
    }

    var dispatch_analysis_index: usize = 0;
    inline for (dispatch_stages, 0..) |stage, index| {
        const registration_index = contract_stages.len + tensor_stages.len + index;
        try testing.expectEqualStrings(stage.name, dispatchPassName(index));
        try testing.expectEqualStrings(
            stage.name,
            accy_choir_pass_registrations[registration_index].name,
        );
        try testing.expectEqualStrings(
            stage.description,
            accy_choir_pass_registrations[registration_index].description,
        );
        try testing.expectEqualStrings(
            stage.pass.name,
            accy_choir_pass_registrations[registration_index].pass.name,
        );

        if (stage.analysis_name) |name| {
            try testing.expectEqualStrings(name, dispatchAnalysisName(dispatch_analysis_index));
            dispatch_analysis_index += 1;
        }
    }

    var memory_analysis_index: usize = 0;
    inline for (memory_stages, 0..) |stage, index| {
        const registration_index = contract_stages.len +
            tensor_stages.len + dispatch_stages.len + index;
        try testing.expectEqualStrings(stage.name, memoryPassName(index));
        try testing.expectEqualStrings(
            stage.name,
            accy_choir_pass_registrations[registration_index].name,
        );
        try testing.expectEqualStrings(
            stage.description,
            accy_choir_pass_registrations[registration_index].description,
        );
        try testing.expectEqualStrings(
            stage.pass.name,
            accy_choir_pass_registrations[registration_index].pass.name,
        );

        if (stage.analysis_name) |name| {
            try testing.expectEqualStrings(name, memoryAnalysisName(memory_analysis_index));
            memory_analysis_index += 1;
        }
    }

    var kernel_analysis_index: usize = 0;
    inline for (kernel_stages, 0..) |stage, index| {
        const registration_index = contract_stages.len +
            tensor_stages.len + dispatch_stages.len + memory_stages.len + index;
        try testing.expectEqualStrings(stage.name, kernelPassName(index));
        try testing.expectEqualStrings(
            stage.name,
            accy_choir_pass_registrations[registration_index].name,
        );
        try testing.expectEqualStrings(
            stage.description,
            accy_choir_pass_registrations[registration_index].description,
        );
        try testing.expectEqualStrings(
            stage.pass.name,
            accy_choir_pass_registrations[registration_index].pass.name,
        );

        if (stage.analysis_name) |name| {
            try testing.expectEqualStrings(name, kernelAnalysisName(kernel_analysis_index));
            kernel_analysis_index += 1;
        }
    }

    var target_analysis_index: usize = 0;
    inline for (target_stages, 0..) |stage, index| {
        const registration_index = contract_stages.len +
            tensor_stages.len + dispatch_stages.len + memory_stages.len + kernel_stages.len + index;
        try testing.expectEqualStrings(stage.name, targetPassName(index));
        try testing.expectEqualStrings(
            stage.name,
            accy_choir_pass_registrations[registration_index].name,
        );
        try testing.expectEqualStrings(
            stage.description,
            accy_choir_pass_registrations[registration_index].description,
        );
        try testing.expectEqualStrings(
            stage.pass.name,
            accy_choir_pass_registrations[registration_index].pass.name,
        );

        if (stage.analysis_name) |name| {
            try testing.expectEqualStrings(name, targetAnalysisName(target_analysis_index));
            target_analysis_index += 1;
        }
    }

    try testing.expectEqual(contract_analysis_index, contract_analysis_count);
    try testing.expectEqual(tensor_analysis_index, tensor_analysis_count);
    try testing.expectEqual(dispatch_analysis_index, dispatch_analysis_count);
    try testing.expectEqual(memory_analysis_index, memory_analysis_count);
    try testing.expectEqual(kernel_analysis_index, kernel_analysis_count);
    try testing.expectEqual(target_analysis_index, target_analysis_count);
}

test "backend preparation stage plans materialize through Choir registry" {
    const allocator = testing.allocator;

    var ctx = try buildBackendPreparationContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, accy_choir_package_extension);

    var pass_registry = passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    try expectStagePlanText(allocator, contract_stages, contract_pass_plan);
    try expectStagePlanText(allocator, tensor_stages, tensor_pass_plan);
    try expectStagePlanText(allocator, dispatch_stages, dispatch_pass_plan);
    try expectStagePlanText(allocator, memory_stages, memory_pass_plan);
    try expectStagePlanText(allocator, kernel_stages, kernel_pass_plan);
    try expectStagePlanText(allocator, target_stages, target_pass_plan);

    var contract_pm = passes.PassManager.init(allocator);
    defer contract_pm.deinit();
    try contract_pass_plan.addTo(&pass_registry, &contract_pm);
    try testing.expectEqual(contract_pass_count, contract_pm.root.pipeline.items.len);

    var tensor_pm = passes.PassManager.init(allocator);
    defer tensor_pm.deinit();
    try tensor_pass_plan.addTo(&pass_registry, &tensor_pm);
    try expectTensorStagePipeline(&tensor_pm);

    var dispatch_pm = passes.PassManager.init(allocator);
    defer dispatch_pm.deinit();
    try dispatch_pass_plan.addTo(&pass_registry, &dispatch_pm);
    try expectDispatchStagePipeline(&dispatch_pm);

    var memory_pm = passes.PassManager.init(allocator);
    defer memory_pm.deinit();
    try memory_pass_plan.addTo(&pass_registry, &memory_pm);
    try expectMemoryStagePipeline(&memory_pm);

    var kernel_pm = passes.PassManager.init(allocator);
    defer kernel_pm.deinit();
    try kernel_pass_plan.addTo(&pass_registry, &kernel_pm);
    try expectKernelStagePipeline(&kernel_pm);

    var target_pm = passes.PassManager.init(allocator);
    defer target_pm.deinit();
    try target_pass_plan.addTo(&pass_registry, &target_pm);
    try expectTargetStagePipeline(&target_pm);
}

test "backend preparation run options expose product controls only" {
    inline for (
        @typeInfo(BackendPreparationRunOptions).@"struct".field_names,
        @typeInfo(BackendPreparationRunOptions).@"struct".field_types,
        @typeInfo(BackendPreparationRunOptions).@"struct".field_attrs,
    ) |field_name, field_name_type, field_name_attrs| {
        const field = .{ .name = field_name, .type = field_name_type, .attrs = field_name_attrs };
        try testing.expect(!std.mem.eql(u8, field.name, "pass_manager"));
        try testing.expect(field.type != passes.PassManagerRunOptions);
    }
}

test "target pipeline materializes from textual Choir registry" {
    const allocator = testing.allocator;

    var ctx = try buildBackendPreparationContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, accy_choir_package_extension);

    var pass_registry = passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try passes.parsePassPipeline(&pass_registry, target_pipeline_name, &pm);
    try expectTargetStagePipeline(&pm);

    const text = try passes.formatPassManagerPipelineAlloc(allocator, &pm);
    defer allocator.free(text);
    try expectTargetStageText(text);
}

test "contract pipeline materializes from textual Choir registry" {
    const allocator = testing.allocator;

    var ctx = try buildBackendPreparationContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, accy_choir_package_extension);

    var pass_registry = passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try passes.parsePassPipeline(&pass_registry, contract_pipeline_name, &pm);

    try testing.expectEqual(contract_pass_count, pm.root.pipeline.items.len);
    inline for (contract_stages, 0..) |stage, index| {
        switch (pm.root.pipeline.items[index]) {
            .pass => |pass| try testing.expectEqualStrings(stage.name, pass.name),
            .nested => try testing.expect(false),
        }
    }
}

test "tensor pipeline materializes from textual Choir registry" {
    const allocator = testing.allocator;

    var ctx = try buildBackendPreparationContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, accy_choir_package_extension);

    var pass_registry = passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try passes.parsePassPipeline(&pass_registry, tensor_pipeline_name, &pm);

    try expectTensorStagePipeline(&pm);
}

test "tensor lowering pass options materialize from textual Choir registry" {
    const allocator = testing.allocator;

    var ctx = try buildBackendPreparationContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, accy_choir_package_extension);

    var pass_registry = passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    const pipeline_text =
        activation_lowering_pass_name ++ "{kernel-library=enabled}," ++
        einsum_lowering_pass_name ++ "{strategy=beam,exact-state-limit=64,beam-width=8," ++
        "auto-beam-width=16,kernel-library=enabled}," ++
        indexing_lowering_pass_name ++
        "{kernel-library=enabled,gather-thread-blocks=4,scatter-thread-blocks=5}," ++
        loss_lowering_pass_name ++
        "{kernel-library=enabled,row-sparse-cross-entropy-thread-blocks=4}";

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try passes.parsePassPipeline(&pass_registry, pipeline_text, &pm);

    try expectTensorStagePipeline(&pm);
    const text = try passes.formatPassManagerPipelineAlloc(allocator, &pm);
    defer allocator.free(text);
    try testing.expectEqualStrings(pipeline_text, text);
}

test "dispatch pipeline materializes from textual Choir registry" {
    const allocator = testing.allocator;

    var ctx = try buildBackendPreparationContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, accy_choir_package_extension);

    var pass_registry = passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try passes.parsePassPipeline(&pass_registry, dispatch_pipeline_name, &pm);

    try expectDispatchStagePipeline(&pm);
}

test "memory pipeline materializes from textual Choir registry" {
    const allocator = testing.allocator;

    var ctx = try buildBackendPreparationContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, accy_choir_package_extension);

    var pass_registry = passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try passes.parsePassPipeline(&pass_registry, memory_pipeline_name, &pm);

    try expectMemoryStagePipeline(&pm);
}

test "kernel pipeline materializes from textual Choir registry" {
    const allocator = testing.allocator;

    var ctx = try buildBackendPreparationContext(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var extension_registry = choir.extensions.ExtensionRegistry.init(allocator);
    defer extension_registry.deinit();
    try extension_registry.registerPackage(&ctx, accy_choir_package_extension);

    var pass_registry = passes.PassRegistry.init(allocator);
    defer pass_registry.deinit();
    try extension_registry.registerPassEntriesTo(&pass_registry);

    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try passes.parsePassPipeline(&pass_registry, kernel_pipeline_name, &pm);

    try expectKernelStagePipeline(&pm);
}

test "runTargetPipeline exposes a direct pipeline helper" {
    const allocator = testing.allocator;

    const module = try buildSemanticAddModule(allocator, "pass_add3", &.{3});
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    try runTargetPipeline(allocator, choir_mod, ctx);

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    try testing.expect(ir.inspection.functionByNameInBlock(body, "pass_add3") != null);
    try testing.expect(!hasFunctionNameSuffix(body, "lowered"));
    try expectPreparedKernelPlan(allocator, choir_mod, ctx, 1);
}

test "runTargetPipelineWithOptions forwards pass manager options" {
    const allocator = testing.allocator;

    const module = try buildSemanticAddMulModule(allocator, "pass_threaded_add_mul", &.{4});
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();

    var worker_gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const status = worker_gpa.deinit();
        testing.expect(status == .ok) catch @panic(
            "target pipeline worker allocator leaked allocations",
        );
    }

    try runTargetPipelineWithOptions(allocator, choir_mod, ctx, .{
        .max_threads = 2,
        .worker_allocator = worker_gpa.allocator(),
    });

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    try testing.expect(ir.inspection.functionByNameInBlock(body, "pass_threaded_add_mul") != null);
    try testing.expect(!hasFunctionNameSuffix(body, "lowered"));
    try expectPreparedKernelPlan(allocator, choir_mod, ctx, 2);
}

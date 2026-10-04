const choir = @import("choir");

const activation_lowering = @import("activation.zig");
const backend_legalization = @import("backend.zig");
const bufferization = @import("bufferization/root.zig");
const canonicalization = @import("canonicalization.zig");
const constant_folding = @import("folding.zig");
const saturation = @import("saturation.zig");
const dtype_legalization = @import("dtype.zig");
const einsum_lowering = @import("einsum.zig");
const fusion = @import("fusion/root.zig");
const indexing_lowering = @import("indexing.zig");
const kernelization = @import("kernelization/root.zig");
const kernel_outlining = @import("outlining/root.zig");
const layout_planning = @import("layout.zig");
const loss_lowering = @import("loss.zig");
const memory_space = @import("memory.zig");
const schedule_planning = @import("schedule/root.zig");
const shape_analysis = @import("shape/root.zig");

const passes = choir.passes;

pub const ActivationLoweringOptions = activation_lowering.Options;
pub const EinsumLoweringOptions = einsum_lowering.Options;
pub const IndexingLoweringOptions = indexing_lowering.Options;
pub const LossLoweringOptions = loss_lowering.Options;
pub const TensorLoweringOptions = struct {
    activation: activation_lowering.Options = .{},
    einsum: einsum_lowering.Options = .{},
    indexing: indexing_lowering.Options = .{},
    loss: loss_lowering.Options = .{},

    pub fn eql(self: TensorLoweringOptions, other: TensorLoweringOptions) bool {
        return self.activation.eql(other.activation) and
            self.einsum.eql(other.einsum) and
            self.indexing.eql(other.indexing) and
            self.loss.eql(other.loss);
    }
};
pub const backend_legalization_pass_name = backend_legalization.backend_legalization_pass_name;
pub const bufferization_planning_pass_name = bufferization.bufferization_planning_pass_name;
pub const canonicalization_pass_name = canonicalization.canonicalization_pass_name;
pub const constant_folding_pass_name = constant_folding.constant_folding_pass_name;
pub const saturation_pass_name = saturation.saturation_pass_name;
pub const dtype_legalization_pass_name = dtype_legalization.dtype_legalization_pass_name;
pub const activation_lowering_pass_name = activation_lowering.activation_lowering_pass_name;
pub const einsum_lowering_pass_name = einsum_lowering.einsum_lowering_pass_name;
pub const indexing_lowering_pass_name = indexing_lowering.indexing_lowering_pass_name;
pub const loss_lowering_pass_name = loss_lowering.loss_lowering_pass_name;
pub const fusion_planning_pass_name = fusion.fusion_planning_pass_name;
pub const kernelization_pass_name = kernelization.kernelization_pass_name;
pub const kernel_outlining_planning_pass_name = kernel_outlining.kernel_outlining_planning_pass_name;
pub const layout_planning_pass_name = layout_planning.layout_planning_pass_name;
pub const memory_space_planning_pass_name = memory_space.memory_space_planning_pass_name;
pub const schedule_planning_pass_name = schedule_planning.schedule_planning_pass_name;
pub const shape_layout_pass_name = shape_analysis.shape_layout_pass_name;

pub fn backendLegalizationPass() passes.Pass {
    return backend_legalization.backendLegalizationPass();
}

pub fn bufferizationPlanningPass() passes.Pass {
    return bufferization.bufferizationPlanningPass();
}

pub fn canonicalizationPass() passes.Pass {
    return canonicalization.canonicalizationPass();
}

pub fn shapeLayoutPropagationPass() passes.Pass {
    return shape_analysis.shapeLayoutPropagationPass();
}

pub fn constantFoldingPass() passes.Pass {
    return constant_folding.constantFoldingPass();
}

pub fn tensorSaturationPass() passes.Pass {
    return saturation.tensorSaturationPass();
}

pub fn dtypeLegalizationPass() passes.Pass {
    return dtype_legalization.dtypeLegalizationPass();
}

pub fn activationLoweringPass() passes.Pass {
    return activation_lowering.activationLoweringPass();
}

pub fn activationLoweringPassWithOptions(options: *const activation_lowering.Options) passes.Pass {
    return activation_lowering.activationLoweringPassWithOptions(options);
}

pub fn einsumLoweringPass() passes.Pass {
    return einsum_lowering.einsumLoweringPass();
}

pub fn einsumLoweringPassWithOptions(options: *const einsum_lowering.Options) passes.Pass {
    return einsum_lowering.einsumLoweringPassWithOptions(options);
}

pub fn indexingLoweringPass() passes.Pass {
    return indexing_lowering.indexingLoweringPass();
}

pub fn indexingLoweringPassWithOptions(options: *const indexing_lowering.Options) passes.Pass {
    return indexing_lowering.indexingLoweringPassWithOptions(options);
}

pub fn lossLoweringPass() passes.Pass {
    return loss_lowering.lossLoweringPass();
}

pub fn lossLoweringPassWithOptions(options: *const loss_lowering.Options) passes.Pass {
    return loss_lowering.lossLoweringPassWithOptions(options);
}

pub fn fusionPlanningPass() passes.Pass {
    return fusion.fusionPlanningPass();
}

pub fn schedulePlanningPass() passes.Pass {
    return schedule_planning.schedulePlanningPass();
}

pub fn kernelOutliningPlanningPass() passes.Pass {
    return kernel_outlining.kernelOutliningPlanningPass();
}

pub fn kernelizationPass() passes.Pass {
    return kernelization.kernelizationPass();
}

pub fn memorySpacePlanningPass() passes.Pass {
    return memory_space.memorySpacePlanningPass();
}

pub fn layoutPlanningPass() passes.Pass {
    return layout_planning.layoutPlanningPass();
}

pub const BackendPreparationStage = struct {
    name: []const u8,
    description: []const u8,
    pass: passes.Pass,
    analysis_name: ?[]const u8 = null,
    options: []const passes.PassOptionSpec = &.{},
    build_with_options: ?passes.PassOptionsBuilderFn = null,

    fn registration(self: BackendPreparationStage) passes.PassRegistration {
        return .{
            .name = self.name,
            .description = self.description,
            .pass = self.pass,
            .options = self.options,
            .build_with_options = self.build_with_options,
        };
    }
};

pub const contract_pipeline_name = "accy-choir-contract";
pub const contract_pipeline_description =
    "Normalize semantic Accy Choir into the backend contract product";
pub const tensor_pipeline_name = "accy-choir-tensor";
pub const tensor_pipeline_description =
    "Materialize tensor-level Accy Choir before dispatch grouping";
pub const dispatch_pipeline_name = "accy-choir-dispatch";
pub const dispatch_pipeline_description =
    "Plan Accy Choir dispatch groups and schedules before memory preparation";
pub const memory_pipeline_name = "accy-choir-memory";
pub const memory_pipeline_description =
    "Plan Accy Choir buffers, memory spaces, and layouts before kernel preparation";
pub const kernel_pipeline_name = "accy-choir-kernel";
pub const kernel_pipeline_description =
    "Outline and lower Accy Choir dispatches into kernel programs before backend legalization";
pub const target_pipeline_name = "accy-choir-target";
pub const target_pipeline_description =
    "Legalize Accy Choir kernels for the selected backend target";

pub const contract_stages = [_]BackendPreparationStage{
    .{
        .name = canonicalization_pass_name,
        .description = canonicalization.canonicalization_pass_description,
        .pass = canonicalizationPass(),
    },
    .{
        .name = saturation_pass_name,
        .description = saturation.saturation_pass_description,
        .pass = tensorSaturationPass(),
    },
    .{
        .name = shape_layout_pass_name,
        .description = shape_analysis.shape_layout_pass_description,
        .pass = shapeLayoutPropagationPass(),
        .analysis_name = shape_analysis.shape_layout_analysis_descriptor.name,
    },
    .{
        .name = constant_folding_pass_name,
        .description = constant_folding.constant_folding_pass_description,
        .pass = constantFoldingPass(),
    },
};

pub const tensor_stages = [_]BackendPreparationStage{
    .{
        .name = activation_lowering_pass_name,
        .description = activation_lowering.activation_lowering_pass_description,
        .pass = activationLoweringPass(),
        .options = &activation_lowering.activation_lowering_pass_options,
        .build_with_options = activation_lowering.activationLoweringPassFromOptions,
    },
    .{
        .name = einsum_lowering_pass_name,
        .description = einsum_lowering.einsum_lowering_pass_description,
        .pass = einsumLoweringPass(),
        .options = &einsum_lowering.einsum_lowering_pass_options,
        .build_with_options = einsum_lowering.einsumLoweringPassFromOptions,
    },
    .{
        .name = indexing_lowering_pass_name,
        .description = indexing_lowering.indexing_lowering_pass_description,
        .pass = indexingLoweringPass(),
        .options = &indexing_lowering.indexing_lowering_pass_options,
        .build_with_options = indexing_lowering.indexingLoweringPassFromOptions,
    },
    .{
        .name = loss_lowering_pass_name,
        .description = loss_lowering.loss_lowering_pass_description,
        .pass = lossLoweringPass(),
        .options = &loss_lowering.loss_lowering_pass_options,
        .build_with_options = loss_lowering.lossLoweringPassFromOptions,
    },
};

pub const dispatch_stages = [_]BackendPreparationStage{
    .{
        .name = fusion_planning_pass_name,
        .description = fusion.fusion_planning_pass_description,
        .pass = fusionPlanningPass(),
        .analysis_name = fusion.fusion_plan_analysis_descriptor.name,
    },
    .{
        .name = schedule_planning_pass_name,
        .description = schedule_planning.schedule_planning_pass_description,
        .pass = schedulePlanningPass(),
        .analysis_name = schedule_planning.schedule_plan_analysis_descriptor.name,
    },
};

pub const memory_stages = [_]BackendPreparationStage{
    .{
        .name = bufferization_planning_pass_name,
        .description = bufferization.bufferization_planning_pass_description,
        .pass = bufferizationPlanningPass(),
        .analysis_name = bufferization.buffer_plan_analysis_descriptor.name,
    },
    .{
        .name = memory_space_planning_pass_name,
        .description = memory_space.memory_space_planning_pass_description,
        .pass = memorySpacePlanningPass(),
        .analysis_name = memory_space.memory_space_plan_analysis_descriptor.name,
    },
    .{
        .name = layout_planning_pass_name,
        .description = layout_planning.layout_planning_pass_description,
        .pass = layoutPlanningPass(),
        .analysis_name = layout_planning.layout_plan_analysis_descriptor.name,
    },
};

pub const kernel_stages = [_]BackendPreparationStage{
    .{
        .name = kernel_outlining_planning_pass_name,
        .description = kernel_outlining.kernel_outlining_planning_pass_description,
        .pass = kernelOutliningPlanningPass(),
        .analysis_name = kernel_outlining.kernel_outline_plan_analysis_descriptor.name,
    },
    .{
        .name = kernelization_pass_name,
        .description = kernelization.kernelization_pass_description,
        .pass = kernelizationPass(),
        .analysis_name = kernelization.kernelization_analysis_descriptor.name,
    },
};

pub const target_stages = [_]BackendPreparationStage{
    .{
        .name = backend_legalization_pass_name,
        .description = backend_legalization.backend_legalization_pass_description,
        .pass = backendLegalizationPass(),
        .analysis_name = backend_legalization.backend_legalization_analysis_descriptor.name,
    },
    .{
        .name = dtype_legalization_pass_name,
        .description = dtype_legalization.dtype_legalization_pass_description,
        .pass = dtypeLegalizationPass(),
    },
};

fn stagePassRegistrations(comptime stages: anytype) [stages.len]passes.PassRegistration {
    comptime {
        var registrations: [stages.len]passes.PassRegistration = undefined;
        for (stages, 0..) |stage, index| {
            registrations[index] = stage.registration();
        }
        return registrations;
    }
}

fn allPassRegistrations() [
    contract_stages.len + tensor_stages.len +
        dispatch_stages.len + memory_stages.len + kernel_stages.len + target_stages.len
]passes.PassRegistration {
    comptime {
        var registrations: [
            contract_stages.len + tensor_stages.len +
                dispatch_stages.len + memory_stages.len + kernel_stages.len + target_stages.len
        ]passes.PassRegistration = undefined;
        for (contract_stages, 0..) |stage, index| {
            registrations[index] = stage.registration();
        }
        for (tensor_stages, 0..) |stage, index| {
            registrations[contract_stages.len + index] = stage.registration();
        }
        for (dispatch_stages, 0..) |stage, index| {
            registrations[contract_stages.len + tensor_stages.len + index] = stage.registration();
        }
        for (memory_stages, 0..) |stage, index| {
            registrations[
                contract_stages.len +
                    tensor_stages.len + dispatch_stages.len + index
            ] = stage.registration();
        }
        for (kernel_stages, 0..) |stage, index| {
            registrations[
                contract_stages.len +
                    tensor_stages.len + dispatch_stages.len + memory_stages.len + index
            ] = stage.registration();
        }
        for (target_stages, 0..) |stage, index| {
            registrations[
                contract_stages.len + tensor_stages.len +
                    dispatch_stages.len + memory_stages.len + kernel_stages.len + index
            ] = stage.registration();
        }
        return registrations;
    }
}

fn stageAnalysisCount(comptime stages: anytype) usize {
    comptime {
        var count: usize = 0;
        for (stages) |stage| {
            if (stage.analysis_name != null) count += 1;
        }
        return count;
    }
}

fn stageAnalysisNames(comptime stages: anytype) [stageAnalysisCount(stages)][]const u8 {
    comptime {
        var names: [stageAnalysisCount(stages)][]const u8 = undefined;
        var next: usize = 0;
        for (stages) |stage| {
            if (stage.analysis_name) |name| {
                names[next] = name;
                next += 1;
            }
        }
        return names;
    }
}

fn stagePlanSteps(comptime stages: anytype) [stages.len]passes.PassPlanStep {
    comptime {
        var steps: [stages.len]passes.PassPlanStep = undefined;
        for (stages, 0..) |stage, index| {
            steps[index] = passes.PassPlanStep.namedPass(stage.name);
        }
        return steps;
    }
}

pub const contract_pipeline_registration = passes.PipelineRegistration{
    .name = contract_pipeline_name,
    .description = contract_pipeline_description,
    .build = buildContractPipeline,
};

pub const tensor_pipeline_registration = passes.PipelineRegistration{
    .name = tensor_pipeline_name,
    .description = tensor_pipeline_description,
    .build = buildTensorPipeline,
};

pub const dispatch_pipeline_registration = passes.PipelineRegistration{
    .name = dispatch_pipeline_name,
    .description = dispatch_pipeline_description,
    .build = buildDispatchPipeline,
};

pub const memory_pipeline_registration = passes.PipelineRegistration{
    .name = memory_pipeline_name,
    .description = memory_pipeline_description,
    .build = buildMemoryPipeline,
};

pub const kernel_pipeline_registration = passes.PipelineRegistration{
    .name = kernel_pipeline_name,
    .description = kernel_pipeline_description,
    .build = buildKernelPipeline,
};

pub const target_pipeline_registration = passes.PipelineRegistration{
    .name = target_pipeline_name,
    .description = target_pipeline_description,
    .build = buildTargetPipeline,
};

pub const contract_pass_registrations = stagePassRegistrations(contract_stages);
pub const tensor_pass_registrations = stagePassRegistrations(tensor_stages);
pub const dispatch_pass_registrations = stagePassRegistrations(dispatch_stages);
pub const memory_pass_registrations = stagePassRegistrations(memory_stages);
pub const kernel_pass_registrations = stagePassRegistrations(kernel_stages);
pub const target_pass_registrations = stagePassRegistrations(target_stages);
pub const accy_choir_pass_registrations = allPassRegistrations();

pub const contract_plan_steps = stagePlanSteps(contract_stages);
pub const tensor_plan_steps = stagePlanSteps(tensor_stages);
pub const dispatch_plan_steps = stagePlanSteps(dispatch_stages);
pub const memory_plan_steps = stagePlanSteps(memory_stages);
pub const kernel_plan_steps = stagePlanSteps(kernel_stages);
pub const target_plan_steps = stagePlanSteps(target_stages);

pub const contract_pass_plan = passes.PassPlan{ .steps = &contract_plan_steps };
pub const tensor_pass_plan = passes.PassPlan{ .steps = &tensor_plan_steps };
pub const dispatch_pass_plan = passes.PassPlan{ .steps = &dispatch_plan_steps };
pub const memory_pass_plan = passes.PassPlan{ .steps = &memory_plan_steps };
pub const kernel_pass_plan = passes.PassPlan{ .steps = &kernel_plan_steps };
pub const target_pass_plan = passes.PassPlan{ .steps = &target_plan_steps };

pub const accy_choir_package_extension = choir.extensions.PackageExtension{
    .name = "accy-choir",
    .passes = &accy_choir_pass_registrations,
    .pipelines = &.{
        contract_pipeline_registration,
        tensor_pipeline_registration,
        dispatch_pipeline_registration,
        memory_pipeline_registration,
        kernel_pipeline_registration,
        target_pipeline_registration,
    },
};

const contract_analysis_names = stageAnalysisNames(contract_stages);
const tensor_analysis_names = stageAnalysisNames(tensor_stages);
const dispatch_analysis_names = stageAnalysisNames(dispatch_stages);
const memory_analysis_names = stageAnalysisNames(memory_stages);
const kernel_analysis_names = stageAnalysisNames(kernel_stages);
const target_analysis_names = stageAnalysisNames(target_stages);

pub const contract_pass_count = contract_stages.len;
pub const contract_analysis_count = contract_analysis_names.len;
pub const tensor_pass_count = tensor_stages.len;
pub const tensor_analysis_count = tensor_analysis_names.len;
pub const dispatch_pass_count = dispatch_stages.len;
pub const dispatch_analysis_count = dispatch_analysis_names.len;
pub const memory_pass_count = memory_stages.len;
pub const memory_analysis_count = memory_analysis_names.len;
pub const kernel_pass_count = kernel_stages.len;
pub const kernel_analysis_count = kernel_analysis_names.len;
pub const target_pass_count = target_stages.len;
pub const target_analysis_count = target_analysis_names.len;

pub fn contractPassName(index: usize) []const u8 {
    return contract_stages[index].name;
}

pub fn contractAnalysisName(index: usize) []const u8 {
    return contract_analysis_names[index];
}

pub fn tensorPassName(index: usize) []const u8 {
    if (comptime tensor_stages.len == 0) {
        unreachable;
    } else {
        return tensor_stages[index].name;
    }
}

pub fn tensorAnalysisName(index: usize) []const u8 {
    if (comptime tensor_analysis_names.len == 0) {
        unreachable;
    } else {
        return tensor_analysis_names[index];
    }
}

pub fn dispatchPassName(index: usize) []const u8 {
    return dispatch_stages[index].name;
}

pub fn dispatchAnalysisName(index: usize) []const u8 {
    return dispatch_analysis_names[index];
}

pub fn memoryPassName(index: usize) []const u8 {
    return memory_stages[index].name;
}

pub fn memoryAnalysisName(index: usize) []const u8 {
    return memory_analysis_names[index];
}

pub fn kernelPassName(index: usize) []const u8 {
    return kernel_stages[index].name;
}

pub fn kernelAnalysisName(index: usize) []const u8 {
    return kernel_analysis_names[index];
}

pub fn targetPassName(index: usize) []const u8 {
    return target_stages[index].name;
}

pub fn targetAnalysisName(index: usize) []const u8 {
    return target_analysis_names[index];
}

pub fn addContractPipeline(pm: *passes.PassManager) !void {
    try contract_pipeline_registration.addTo(&pm.root);
}

pub fn addTensorPipeline(pm: *passes.PassManager) !void {
    try tensor_pipeline_registration.addTo(&pm.root);
}

pub fn addTensorPipelineWithOptions(
    pm: *passes.PassManager,
    options: *const TensorLoweringOptions,
) !void {
    try pm.addPass(activationLoweringPassWithOptions(&options.activation));
    try pm.addPass(einsumLoweringPassWithOptions(&options.einsum));
    try pm.addPass(indexingLoweringPassWithOptions(&options.indexing));
    try pm.addPass(lossLoweringPassWithOptions(&options.loss));
}

pub fn addDispatchPipeline(pm: *passes.PassManager) !void {
    try dispatch_pipeline_registration.addTo(&pm.root);
}

pub fn addMemoryPipeline(pm: *passes.PassManager) !void {
    try memory_pipeline_registration.addTo(&pm.root);
}

pub fn addKernelPipeline(pm: *passes.PassManager) !void {
    try kernel_pipeline_registration.addTo(&pm.root);
}

pub fn addTargetPipeline(pm: *passes.PassManager) !void {
    try target_pipeline_registration.addTo(&pm.root);
}

fn buildContractPipeline(pm: *passes.OpPassManager) anyerror!void {
    try buildStagePlan(pm, contract_pass_plan, &contract_pass_registrations);
}

fn buildTensorPipeline(pm: *passes.OpPassManager) anyerror!void {
    try buildStagePlan(pm, tensor_pass_plan, &tensor_pass_registrations);
}

fn buildDispatchPipeline(pm: *passes.OpPassManager) anyerror!void {
    try buildStagePlan(pm, dispatch_pass_plan, &dispatch_pass_registrations);
}

fn buildMemoryPipeline(pm: *passes.OpPassManager) anyerror!void {
    try buildStagePlan(pm, memory_pass_plan, &memory_pass_registrations);
}

fn buildKernelPipeline(pm: *passes.OpPassManager) anyerror!void {
    try buildStagePlan(pm, kernel_pass_plan, &kernel_pass_registrations);
}

fn buildTargetPipeline(pm: *passes.OpPassManager) anyerror!void {
    try buildStagePlan(pm, target_pass_plan, &target_pass_registrations);
}

fn buildStagePlan(
    pm: *passes.OpPassManager,
    pass_plan: passes.PassPlan,
    registrations: []const passes.PassRegistration,
) anyerror!void {
    var registry = passes.PassRegistry.init(pm.allocator);
    defer registry.deinit();
    for (registrations) |registration| {
        try registry.registerPass(registration);
    }
    try pass_plan.addToOp(&registry, pm);
}

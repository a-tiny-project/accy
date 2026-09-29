const std = @import("std");
const choir = @import("../../root.zig");
const spirv = @import("spirv/root.zig");
const nvptx = @import("nvptx/root.zig");

pub const gpu_to_spirv_pipeline_name = "gpu-to-spirv-pipeline";
pub const gpu_to_spirv_pipeline_description = "Lower the GPU dialect to the SPIR-V target dialect";

pub const gpu_to_nvptx_pipeline_name = "gpu-to-nvptx-pipeline";
pub const gpu_to_nvptx_pipeline_description = "Lower the GPU dialect to the NVPTX target dialect";

pub const TargetLowering = enum {
    spirv,
    nvptx,
};

const Stage = struct {
    lowering: TargetLowering,
    target_spec: choir.backends.TargetSpec,
    pass_registration: choir.passes.PassRegistration,
    pipeline_registration: choir.passes.PipelineRegistration,
};

fn buildGpuToSpirvPipeline(pm: *choir.passes.OpPassManager) anyerror!void {
    try pm.addPass(spirv.createGpuToSpirvPass());
}

fn buildGpuToNvptxPipeline(pm: *choir.passes.OpPassManager) anyerror!void {
    try pm.addPass(nvptx.createGpuToNvptxPass());
}

pub const gpu_to_spirv_pipeline_registration = choir.passes.PipelineRegistration{
    .name = gpu_to_spirv_pipeline_name,
    .description = gpu_to_spirv_pipeline_description,
    .build = buildGpuToSpirvPipeline,
};

pub const gpu_to_nvptx_pipeline_registration = choir.passes.PipelineRegistration{
    .name = gpu_to_nvptx_pipeline_name,
    .description = gpu_to_nvptx_pipeline_description,
    .build = buildGpuToNvptxPipeline,
};

fn targetSpecWithPipeline(
    spec: choir.backends.TargetSpec,
    pipeline_registration: choir.passes.PipelineRegistration,
) choir.backends.TargetSpec {
    var target_spec = spec;
    target_spec.pipeline_name = pipeline_registration.name;
    target_spec.pipeline_description = pipeline_registration.description;
    return target_spec;
}

const stages = [_]Stage{
    .{
        .lowering = .spirv,
        .target_spec = targetSpecWithPipeline(spirv.target_spec, gpu_to_spirv_pipeline_registration),
        .pass_registration = spirv.pass_registration,
        .pipeline_registration = gpu_to_spirv_pipeline_registration,
    },
    .{
        .lowering = .nvptx,
        .target_spec = targetSpecWithPipeline(nvptx.target_spec, gpu_to_nvptx_pipeline_registration),
        .pass_registration = nvptx.pass_registration,
        .pipeline_registration = gpu_to_nvptx_pipeline_registration,
    },
};

fn passRegistrations() [stages.len]choir.passes.PassRegistration {
    comptime {
        var registrations: [stages.len]choir.passes.PassRegistration = undefined;
        for (stages, 0..) |stage, index| {
            registrations[index] = stage.pass_registration;
        }
        return registrations;
    }
}

fn pipelineRegistrations() [stages.len]choir.passes.PipelineRegistration {
    comptime {
        var registrations: [stages.len]choir.passes.PipelineRegistration = undefined;
        for (stages, 0..) |stage, index| {
            registrations[index] = stage.pipeline_registration;
        }
        return registrations;
    }
}

fn stageFor(lowering: TargetLowering) Stage {
    return switch (lowering) {
        .spirv => stages[0],
        .nvptx => stages[1],
    };
}

fn specs() [stages.len]choir.backends.TargetSpec {
    comptime {
        var registrations: [stages.len]choir.backends.TargetSpec = undefined;
        for (stages, 0..) |stage, index| {
            registrations[index] = stage.target_spec;
        }
        return registrations;
    }
}

pub const pass_registrations = passRegistrations();
pub const pipeline_registrations = pipelineRegistrations();
pub const target_specs = specs();
pub const spirv_target_spec = target_specs[0];
pub const nvptx_target_spec = target_specs[1];
pub const target_lowering_stage_count = stages.len;
pub const target_spec_count = target_specs.len;
pub const target_lowering_pass_count = pass_registrations.len;
pub const target_lowering_pipeline_count = pipeline_registrations.len;

pub fn targetLoweringPassName(index: usize) []const u8 {
    return stages[index].pass_registration.name;
}

pub fn targetLoweringPipelineName(index: usize) []const u8 {
    return stages[index].pipeline_registration.name;
}

pub fn targetLoweringTargetDialectName(index: usize) []const u8 {
    return stages[index].target_spec.target_dialect_name;
}

pub fn targetLoweringSpec(index: usize) choir.backends.TargetSpec {
    return target_specs[index];
}

pub fn addGpuToSpirvPipeline(pm: *choir.passes.PassManager) !void {
    try gpu_to_spirv_pipeline_registration.addTo(&pm.root);
}

pub fn addGpuToNvptxPipeline(pm: *choir.passes.PassManager) !void {
    try gpu_to_nvptx_pipeline_registration.addTo(&pm.root);
}

pub fn addTargetLoweringPipeline(pm: *choir.passes.PassManager, lowering: TargetLowering) !void {
    try stageFor(lowering).pipeline_registration.addTo(&pm.root);
}

test "target lowering stage table defines registries" {
    const testing = std.testing;

    try testing.expectEqual(stages.len, target_lowering_stage_count);
    try testing.expectEqual(stages.len, target_spec_count);
    try testing.expectEqual(stages.len, target_lowering_pass_count);
    try testing.expectEqual(stages.len, target_lowering_pipeline_count);
    try testing.expectEqual(stages.len, target_specs.len);
    try testing.expectEqual(stages.len, pass_registrations.len);
    try testing.expectEqual(stages.len, pipeline_registrations.len);

    inline for (stages, 0..) |stage, index| {
        try testing.expectEqual(stage.lowering, stageFor(stage.lowering).lowering);
        const target_spec = targetLoweringSpec(index);
        try testing.expectEqualStrings(stage.target_spec.name, target_spec.name);
        try testing.expectEqualStrings(stage.target_spec.target_dialect_name, targetLoweringTargetDialectName(index));
        try testing.expectEqualStrings(stage.target_spec.target_dialect_name, target_spec.target_dialect_name);
        try testing.expectEqualStrings(stage.target_spec.pass_name, stage.pass_registration.name);
        try testing.expectEqualStrings(stage.target_spec.pass_description, stage.pass_registration.description);
        try testing.expectEqualStrings(stage.target_spec.pipeline_name, stage.pipeline_registration.name);
        try testing.expectEqualStrings(stage.target_spec.pipeline_description, stage.pipeline_registration.description);
        try testing.expect(stage.target_spec.legalizesDialect(stage.target_spec.target_dialect_name));
        try testing.expectEqualStrings(stage.pass_registration.name, targetLoweringPassName(index));
        try testing.expectEqualStrings(stage.pass_registration.name, pass_registrations[index].name);
        try testing.expectEqualStrings(stage.pass_registration.description, pass_registrations[index].description);
        try testing.expectEqualStrings(stage.pass_registration.pass.name, pass_registrations[index].pass.name);
        try testing.expectEqualStrings(stage.pipeline_registration.name, targetLoweringPipelineName(index));
        try testing.expectEqualStrings(stage.pipeline_registration.name, pipeline_registrations[index].name);
        try testing.expectEqualStrings(stage.pipeline_registration.description, pipeline_registrations[index].description);
    }
}

const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const lowering = @import("root.zig");
const preparation = @import("../../root.zig");
const product_mod = @import("../model/root.zig");
const common = lowering.common;
const elementwise = lowering.elementwise;
const shape_lowering = lowering.shape_lowering;
const dot = lowering.dot;
const reduction = lowering.reduction;
const row_pipeline = lowering.row_pipeline;
const iterate_lowering = lowering.iterate_lowering;
const flash_attention = lowering.flash_attention;
const scan_lowering = lowering.scan_lowering;
const ir = choir.ir;
const passes = choir.passes;
const bufferization = preparation.bufferization;
const kernel_outlining = preparation.outlining;
const schedule_planning = preparation.schedule;
const shape_analysis = preparation.shape;
const KernelizationAnalysis = product_mod.KernelizationAnalysis;
const LoweredKernel = product_mod.LoweredKernel;

pub const kernelization_analysis_name = "accy-choir-kernelization-plan";
pub const kernelization_pass_name = "accy-choir-plan-kernelization";
pub const kernelization_pass_description =
    "Lower scheduled Accy tensor work to kernel-language programs";

pub const kernelization_analysis_descriptor = passes.AnalysisDescriptor{
    .id = passes.analysisId(kernelization_analysis_name),
    .name = kernelization_analysis_name,
    .work_contract = .{
        .identity = .{ .name = kernelization_analysis_name, .version = 1 },
        .estimate = lowering.work.analysis,
    },
};

pub fn getKernelizationAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) !*KernelizationAnalysis {
    const ptr = try pass_ctx.getAnalysis(
        op,
        &kernelization_analysis_descriptor,
        computeKernelizationAnalysis,
        cleanupKernelizationAnalysis,
    );
    return @ptrCast(@alignCast(ptr));
}

pub fn kernelizationPass() passes.Pass {
    return .{
        .name = kernelization_pass_name,
        .description = kernelization_pass_description,
        .run_fn = runKernelizationPass,
        .work_contract = .{
            .identity = .{ .name = kernelization_pass_name, .version = 1 },
            .estimate = lowering.work.pass,
        },
    };
}

fn runKernelizationPass(pass_ctx: *passes.PassContext) passes.PassResult {
    _ = getKernelizationAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
    pass_ctx.preserveAllAnalyses();
    return .success;
}

fn computeKernelizationAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) anyerror!*anyopaque {
    if (op.context != pass_ctx.ir_ctx) return error.InvalidArtifact;
    const schedule_plan = try schedule_planning.getSchedulePlanAnalysis(pass_ctx, op);
    const outline_plan = try kernel_outlining.getKernelOutlinePlanAnalysis(pass_ctx, op);
    const buffer_plan = try bufferization.getBufferPlanAnalysis(pass_ctx, op);
    const shape_plan = try shape_analysis.getShapeLayoutAnalysis(pass_ctx, op);
    const target_profile = preparation.readBackendTargetProfile(op);
    const format: ?gpu.ArtifactFormat = if (target_profile) |profile|
        profile.artifact_format
    else
        null;
    const math_tier: gpu.BackendMathTier = if (target_profile) |profile|
        profile.math_tier
    else
        .exact;
    const scan_schedules = preparation.target.readGeneratedScanSchedules(op);
    const row_pipeline_schedules = preparation.target.readGeneratedRowPipelineSchedules(op);

    const analysis = try pass_ctx.allocator.create(KernelizationAnalysis);
    analysis.* = KernelizationAnalysis.init(
        pass_ctx.allocator,
        pass_ctx.ir_ctx.capacity.asLimits(),
    ) catch |err| {
        pass_ctx.allocator.destroy(analysis);
        return common.mapKernelBuildError(err);
    };
    errdefer {
        analysis.deinit();
        pass_ctx.allocator.destroy(analysis);
    }

    try analysis.reserveKernelCapacity(outline_plan.kernels.items.len);

    for (outline_plan.kernels.items) |outline| {
        const work = workItemById(schedule_plan, outline.work_item_id) orelse
            return error.MissingScheduleWorkItem;
        if (try lowerKernel(
            pass_ctx.allocator,
            analysis.context,
            outline,
            work.*,
            buffer_plan,
            shape_plan,
            format,
            math_tier,
            scan_schedules,
            row_pipeline_schedules,
        )) |kernel| {
            var owned = kernel;
            var transferred = false;
            errdefer if (!transferred) owned.deinit(pass_ctx.allocator);
            try product_mod.addKernel(analysis, owned);
            transferred = true;
        }
    }

    return @ptrCast(analysis);
}

fn cleanupKernelizationAnalysis(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const analysis: *KernelizationAnalysis = @ptrCast(@alignCast(ptr));
    analysis.deinit();
    allocator.destroy(analysis);
}

fn lowerKernel(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: product_mod.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    shape_plan: *const shape_analysis.ShapeLayoutAnalysis,
    format: ?gpu.ArtifactFormat,
    math_tier: gpu.BackendMathTier,
    scan_schedules: ?[]const u8,
    row_pipeline_schedules: ?[]const u8,
) !?LoweredKernel {
    return lowerKernelStrict(
        allocator,
        ir_ctx,
        outline,
        work,
        buffer_plan,
        shape_plan,
        format,
        math_tier,
        scan_schedules,
        row_pipeline_schedules,
    ) catch |err| switch (err) {
        error.UnsupportedOperation,
        error.UnsupportedArtifactFormat,
        error.CapabilityMismatch,
        => if (math_tier == .exact) null else return err,
        else => |other| return other,
    };
}

fn lowerKernelStrict(
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,
    outline: product_mod.KernelOutline,
    work: schedule_planning.ScheduleWorkItem,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    shape_plan: *const shape_analysis.ShapeLayoutAnalysis,
    format: ?gpu.ArtifactFormat,
    math_tier: gpu.BackendMathTier,
    scan_schedules: ?[]const u8,
    row_pipeline_schedules: ?[]const u8,
) common.LoweringError!LoweredKernel {
    return switch (outline.kind) {
        .elementwise => elementwise.lower(
            allocator,
            ir_ctx,
            outline,
            work,
            buffer_plan,
            shape_plan,
            format,
        ),
        .shape => shape_lowering.lower(allocator, ir_ctx, outline, work, buffer_plan),
        .dot_general => dot.lower(allocator, ir_ctx, outline, work, buffer_plan, format, math_tier),
        .reduction => reduction.lower(allocator, ir_ctx, outline, work, buffer_plan, format),
        .row_pipeline => row_pipeline.lower(
            allocator,
            ir_ctx,
            outline,
            work,
            buffer_plan,
            format,
            row_pipeline_schedules,
        ),
        .iterate => iterate_lowering.lower(allocator, ir_ctx, outline, work, buffer_plan),
        .flash_attention => flash_attention.lower(
            allocator,
            ir_ctx,
            outline,
            work,
            buffer_plan,
            format,
        ),
        .scan => scan_lowering.lower(
            allocator,
            ir_ctx,
            outline,
            work,
            buffer_plan,
            format,
            scan_schedules,
        ),
        .kernel_call => error.UnsupportedOperation,
    };
}

fn workItemById(
    schedule_plan: *const schedule_planning.SchedulePlanAnalysis,
    work_item_id: usize,
) ?*const schedule_planning.ScheduleWorkItem {
    if (work_item_id < schedule_plan.work_items.items.len) {
        const work = &schedule_plan.work_items.items[work_item_id];
        if (work.id == work_item_id) return work;
    }
    for (schedule_plan.work_items.items) |*work| {
        if (work.id == work_item_id) return work;
    }
    return null;
}

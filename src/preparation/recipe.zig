const std = @import("std");
const choir = @import("choir");
const stage_owner = @import("stage.zig");
const run = @import("run.zig");
const target = @import("target.zig");
const accy_choir = @import("../choir/root.zig");
const records = accy_choir.record;
const Stage = accy_choir.publication.Stage;
const Options = run.BackendPreparationRunOptions;
const library = @import("../kernel/library/root.zig");

pub const identity = choir.product.revision.record.Version{
    .name = "accy-stage-recipe",
    .version = 1,
};

pub const Policy = struct {
    max_threads: usize = 1,
    worker_allocator: ?void = null,
    verification: choir.ir.VerifyOptions = choir.ir.verify.default_options,
};

pub const policy = Policy{};

pub fn runOptions() choir.passes.PassManagerRunOptions {
    return .{ .max_threads = policy.max_threads, .worker_allocator = null };
}

pub fn pipelineName(comptime stage: Stage) []const u8 {
    return @field(stage_owner, @tagName(stage) ++ "_pipeline_name");
}

/// The compile chain records this list with each stage so a change to the pass pipeline changes the
/// stage record, the sealed result of one compile stage. The function returns the ordered
/// identities of the passes in the stage's pipeline: each pass's declared name, version and cost
/// estimate, or its name at version 1 when it has none. The list is derived at compile time from
/// the same stage declarations that build the pipeline, so the recorded list and the pipeline that
/// runs cannot drift apart.
pub fn pipeline(comptime stage: Stage) []const choir.product.revision.record.Version {
    const declarations = comptime stages(stage);
    const identities = comptime blk: {
        var result: [declarations.len]choir.product.revision.record.Version = undefined;
        for (declarations, 0..) |entry, index| {
            result[index] = if (entry.pass.work_contract) |contract|
                contract.identity
            else
                .{ .name = entry.name, .version = 1 };
        }
        break :blk result;
    };
    return &identities;
}

fn stages(comptime stage: Stage) []const stage_owner.BackendPreparationStage {
    return switch (stage) {
        .semantic => &.{},
        .contract => &stage_owner.contract_stages,
        .tensor => &stage_owner.tensor_stages,
        .dispatch => &stage_owner.dispatch_stages,
        .memory => &stage_owner.memory_stages,
        .kernel => &stage_owner.kernel_stages,
        .target => &stage_owner.target_stages,
    };
}

/// The compile chain calls this to fill a pass manager with one stage's pipeline. The call turns on
/// verification and adds the stage's passes to `manager`. The tensor stage's passes borrow
/// `options.tensor`, so `options` must outlive `manager`.
pub fn configure(
    manager: *choir.passes.PassManager,
    comptime stage: Stage,
    options: *const Options,
) !void {
    manager.enableVerifierWithOptions(policy.verification);
    switch (stage) {
        .semantic => {},
        .contract => try stage_owner.addContractPipeline(manager),
        .tensor => try stage_owner.addTensorPipelineWithOptions(manager, &options.tensor),
        .dispatch => try stage_owner.addDispatchPipeline(manager),
        .memory => try stage_owner.addMemoryPipeline(manager),
        .kernel => try stage_owner.addKernelPipeline(manager),
        .target => try stage_owner.addTargetPipeline(manager),
    }
}

/// The compile chain calls this to write a request's target settings, the device profile and
/// per-kernel schedule choices stored on the module, onto a module in a mutable compiler job. The
/// call writes the device profile when one is set, and the scan and row schedule choices when their
/// lists are non-empty. An unset profile or an empty list leaves the setting inherited from the
/// source exactly as it was.
pub fn applyTargetOptions(
    allocator: std.mem.Allocator,
    root: *choir.ir.Operation,
    options: Options,
) !void {
    if (options.target_profile) |profile| {
        try target.setBackendTargetProfile(root.context, root, profile);
    }
    if (options.generated_scan_schedules.len != 0) {
        try target.setGeneratedScanSchedules(
            allocator,
            root.context,
            root,
            options.generated_scan_schedules,
        );
    }
    if (options.generated_row_pipeline_schedules.len != 0) {
        try target.setGeneratedRowPipelineSchedules(
            allocator,
            root.context,
            root,
            options.generated_row_pipeline_schedules,
        );
    }
}

const Einsum = struct {
    strategy: accy_choir.einsum.Strategy,
    exact_state_limit: usize,
    beam_width: usize,
    auto_beam_width: usize,
    kernel_library: @import("library.zig").KernelLibraryLowering,
    matrix_product_schedule: ?library.MatrixProductSchedule,
    matrix_product_tuning: ?library.linalg.MatrixProductScheduleReader = null,
    family_tuning: ?library.tuning.FamilyTuningReader = null,
};

const Indexing = struct {
    kernel_library: @import("library.zig").KernelLibraryLowering,
    gather_schedule: ?library.GatherSchedule,
    scatter_schedule: ?library.ScatterSchedule,
    scatter_add_schedule: ?library.ScatterAddSchedule,
    family_tuning: ?library.tuning.FamilyTuningReader = null,
};

const Tensor = struct {
    activation: stage_owner.ActivationLoweringOptions,
    einsum: Einsum,
    indexing: Indexing,
    loss: stage_owner.LossLoweringOptions,
};

pub const TargetInputs = struct {
    profile: ?target.BackendTargetProfile,
    generated_scan_schedules: ?[]const u8,
    generated_row_pipeline_schedules: ?[]const u8,
};

fn Lowering(comptime stage: Stage) type {
    return switch (stage) {
        .tensor => Tensor,
        .kernel, .target => TargetInputs,
        else => struct {},
    };
}

pub fn Record(comptime stage: Stage) type {
    return struct { execution: Policy, options: Lowering(stage) };
}

/// The compile chain calls this to encode the options a stage ran with, for its stage record. The
/// call reads the target settings already on `root` without changing the module, applies the
/// request's overrides, and returns bytes the caller owns. An empty override keeps the inherited
/// setting. A tuning table given in the options is recorded with its device facts and its records
/// in order, so a table that lacks a key is recorded as lacking it. Timing, the failure destination
/// and the clock are administrative and are left out, so they never change a record.
pub fn encode(
    allocator: std.mem.Allocator,
    comptime stage: Stage,
    root: *choir.ir.Operation,
    options: Options,
) ![]u8 {
    return encodeWithTarget(allocator, stage, .{
        .profile = target.readBackendTargetProfile(root),
        .generated_scan_schedules = target.readGeneratedScanSchedules(root),
        .generated_row_pipeline_schedules = target.readGeneratedRowPipelineSchedules(root),
    }, options);
}

/// The compile chain calls this to encode a stage's options from a retained source without a
/// mutable module at hand. The call starts from the target settings captured from the original
/// source, applies this request's overrides, and returns bytes the caller owns. The call decodes
/// its own output and compares it with the input before returning, so a value that does not survive
/// encoding is caught at once.
pub fn encodeWithTarget(
    allocator: std.mem.Allocator,
    comptime stage: Stage,
    inherited: TargetInputs,
    options: Options,
) ![]u8 {
    comptime classify();
    const scan = if ((stage == .kernel or stage == .target) and
        options.generated_scan_schedules.len != 0)
        try target.encodeGeneratedScanSchedules(allocator, options.generated_scan_schedules)
    else
        null;
    defer if (scan) |bytes| allocator.free(bytes);
    const row = if ((stage == .kernel or stage == .target) and
        options.generated_row_pipeline_schedules.len != 0)
        try target.encodeGeneratedRowPipelineSchedules(
            allocator,
            options.generated_row_pipeline_schedules,
        )
    else
        null;
    defer if (row) |bytes| allocator.free(bytes);
    const source = switch (stage) {
        .tensor => options.tensor,
        .kernel, .target => TargetInputs{
            .profile = options.target_profile orelse inherited.profile,
            .generated_scan_schedules = scan orelse inherited.generated_scan_schedules,
            .generated_row_pipeline_schedules = row orelse
                inherited.generated_row_pipeline_schedules,
        },
        else => Lowering(stage){},
    };
    var references = records.reference.Index{ .allocator = allocator, .limit = 0 };
    defer references.deinit();
    const effective = .{ .execution = policy, .options = source };
    const bytes = try records.codec.encode(allocator, Record(stage), stage, effective, &references);
    errdefer allocator.free(bytes);
    var decoded = try records.codec.decode(allocator, Record(stage), stage, bytes);
    defer decoded.deinit();
    try records.codec.compare(decoded.value, effective, &references);
    return bytes;
}

fn classify() void {
    const fields = choir.product.revision.record.requireFields;
    fields(Policy, &.{ "max_threads", "worker_allocator", "verification" });
    // `pool` and `deal` choose where and in what order items run. Output does not depend on
    // either, so the policy record carries neither.
    fields(choir.passes.PassManagerRunOptions, &.{
        "max_threads",
        "worker_allocator",
        "pool",
        "deal",
    });
    fields(choir.ir.VerifyOptions, &.{
        "check_terminators",     "require_terminators", "recursive", "check_use_def",
        "check_local_dominance", "check_cfg",           "max_depth",
    });
    fields(Options, &.{
        "timing",                           "failure", "target_profile", "generated_scan_schedules",
        "generated_row_pipeline_schedules", "tensor",  "now",
    });
    records.codec.coverage(stage_owner.TensorLoweringOptions, Tensor, &.{});
    records.codec.coverage(stage_owner.EinsumLoweringOptions, Einsum, &.{});
    records.codec.coverage(stage_owner.IndexingLoweringOptions, Indexing, &.{});
    fields(stage_owner.ActivationLoweringOptions, &.{"kernel_library"});
    fields(stage_owner.LossLoweringOptions, &.{
        "kernel_library", "row_sparse_cross_entropy_schedule",
    });
    fields(target.BackendTargetProfile, &.{
        "backend_kind", "artifact_format", "math_tier", "dtype_bits", "feature_bits",
    });
}

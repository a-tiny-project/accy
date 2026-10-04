const std = @import("std");
const gpu = @import("gpu");
const artifact = @import("root.zig");
const model = @import("model/root.zig");
const target = @import("../target/root.zig");

const fingerprint_mod = artifact.fingerprint;
const plan = artifact.plan;

const ArtifactPlanOptions = model.ArtifactPlanOptions;
const BackendArtifactPlan = plan.BackendArtifactPlan;

/// A heap-allocated holder of one artifact plan, the compiled kernels and the
/// plan that describes them. A caller holds one of these between compiling a
/// prepared program to device code and copying that code into a runnable
/// program. `init` takes ownership of the plan and allocates the holder with
/// the given allocator, and `deinit` frees the plan and then the holder. The
/// holder lives only as long as the compile that made it and is never stored as
/// a stage record. The holder answers kernel counts and per-kernel summaries by
/// index or by work item, and it copies the plan or the summaries out for a
/// caller to keep.
pub const ArtifactJob = struct {
    allocator: std.mem.Allocator,
    artifact_plan: BackendArtifactPlan,

    pub fn init(
        allocator: std.mem.Allocator,
        artifact_plan: BackendArtifactPlan,
    ) !*ArtifactJob {
        const artifact_job = try allocator.create(ArtifactJob);
        errdefer allocator.destroy(artifact_job);
        artifact_job.* = .{
            .allocator = allocator,
            .artifact_plan = artifact_plan,
        };
        return artifact_job;
    }

    pub fn deinit(self: *ArtifactJob) void {
        self.artifact_plan.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// A 64-bit hash of the plan's target profile, kind, format, slots, input
    /// and output ids, kernels and totals. A caller shows this number in
    /// reports or stamps it beside compiled output as a label, and no identity
    /// check or reuse decision compares it.
    pub fn fingerprint(self: *const ArtifactJob) u64 {
        return fingerprint_mod.artifactPlan(&self.artifact_plan);
    }

    pub fn kernelCount(self: *const ArtifactJob) usize {
        return self.artifact_plan.kernelCount();
    }

    pub fn kernelSummary(
        self: *const ArtifactJob,
        kernel_index: usize,
    ) gpu.BackendError!artifact.KernelSummary {
        if (kernel_index >= self.artifact_plan.kernels.items.len) return error.InvalidArtifact;
        return try artifact.summarizePlannedKernel(self.artifact_plan.kernels.items[kernel_index]);
    }

    pub fn kernelSummaryForWork(
        self: *const ArtifactJob,
        work_item_id: usize,
    ) gpu.BackendError!artifact.KernelSummary {
        for (self.artifact_plan.kernels.items) |kernel| {
            if (kernel.work_item_id == work_item_id) {
                return try artifact.summarizePlannedKernel(kernel);
            }
        }
        return error.InvalidArtifact;
    }

    pub fn artifactPlan(self: *const ArtifactJob) *const BackendArtifactPlan {
        return &self.artifact_plan;
    }

    pub fn copyKernelSummaries(
        self: *const ArtifactJob,
        result_allocator: std.mem.Allocator,
    ) gpu.BackendError!artifact.KernelSummaries {
        const items = result_allocator.alloc(
            artifact.KernelSummary,
            self.artifact_plan.kernels.items.len,
        ) catch return error.OutOfMemory;
        var copied: usize = 0;
        errdefer {
            for (items[0..copied]) |summary| {
                result_allocator.free(summary.entry_name);
            }
            result_allocator.free(items);
        }

        for (items, self.artifact_plan.kernels.items) |*item, kernel| {
            item.* = try artifact.copyKernelSummary(
                result_allocator,
                try artifact.summarizePlannedKernel(kernel),
            );
            copied += 1;
        }

        return .{
            .allocator = result_allocator,
            .items = items,
        };
    }

    pub fn copyArtifactPlan(
        self: *const ArtifactJob,
        allocator: std.mem.Allocator,
    ) gpu.BackendError!BackendArtifactPlan {
        return try self.artifact_plan.copy(allocator);
    }
};

pub fn createArtifactJobFromTargetJob(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    target_module: *target.TargetJob,
    options: ArtifactPlanOptions,
) !*ArtifactJob {
    var artifact_plan = try plan.createBackendArtifactPlanFromTargetJob(
        allocator,
        handle,
        target_module,
        options,
    );
    var plan_owned = true;
    errdefer if (plan_owned) artifact_plan.deinit();

    const artifact_job = try ArtifactJob.init(
        allocator,
        artifact_plan,
    );
    plan_owned = false;
    return artifact_job;
}

test "artifact job fingerprint includes artifact plan identity" {
    const allocator = std.testing.allocator;

    var first_plan = BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    var first_plan_owned = true;
    errdefer if (first_plan_owned) first_plan.deinit();

    const first = try ArtifactJob.init(allocator, first_plan);
    first_plan_owned = false;
    defer first.deinit();

    var second_plan = BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{ .f16, .f32 }).bits,
    });
    var second_plan_owned = true;
    errdefer if (second_plan_owned) second_plan.deinit();

    const second = try ArtifactJob.init(allocator, second_plan);
    second_plan_owned = false;
    defer second.deinit();

    try std.testing.expect(first.fingerprint() != second.fingerprint());
}

test "artifact job exposes kernel count" {
    const allocator = std.testing.allocator;

    var artifact_plan = BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    var plan_owned = true;
    errdefer if (plan_owned) artifact_plan.deinit();

    const module = try ArtifactJob.init(allocator, artifact_plan);
    plan_owned = false;
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 0), module.kernelCount());
}

test "artifact job exposes kernel summaries by index and work item" {
    const allocator = std.testing.allocator;

    var artifact_plan = BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    var plan_owned = true;
    errdefer if (plan_owned) artifact_plan.deinit();

    var kernel_artifact = try gpu.KernelArtifact.init(allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = "artifact_summary_kernel",
        .argument_count = 0,
    });
    var artifact_owned = true;
    errdefer if (artifact_owned) kernel_artifact.deinit();
    try kernel_artifact.setOwnedText("payload");

    var compile = try artifact.PlannedKernelCompileContract.init(
        allocator,
        .choir_kernel,
        .authored,
        .cuda_ptx,
        "artifact_summary_kernel",
        0,
        gpu.DTypeSet.init(&.{.f32}),
        .{},
        .{},
        null,
        .{ .text = "payload" },
    );
    var compile_owned = true;
    errdefer if (compile_owned) compile.deinit(allocator);

    try artifact_plan.addStandaloneKernel(
        kernel_artifact,
        .{
            .format = .cuda_ptx,
            .element_count = 1,
            .geometry = .{
                .grid = .{ 1, 1, 1 },
                .threadgroup = .{ 1, 1, 1 },
            },
        },
        compile,
        .{},
    );
    artifact_owned = false;
    compile_owned = false;

    const module = try ArtifactJob.init(allocator, artifact_plan);
    plan_owned = false;
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.kernelCount());
    const indexed = try module.kernelSummary(0);
    const by_work = try module.kernelSummaryForWork(indexed.work_item_id);
    try std.testing.expectEqualStrings(indexed.entry_name, by_work.entry_name);
    try std.testing.expectEqual(indexed.work_item_id, by_work.work_item_id);
    try std.testing.expectEqual(artifact.KernelSource.choir_kernel, indexed.source);
    try std.testing.expectError(error.InvalidArtifact, module.kernelSummary(1));
    try std.testing.expectError(error.InvalidArtifact, module.kernelSummaryForWork(99));

    var summaries = try module.copyKernelSummaries(allocator);
    defer summaries.deinit();
    try std.testing.expectEqual(@as(usize, 1), summaries.len());
    const copied = try summaries.summaryForWork(indexed.work_item_id);
    try std.testing.expectEqualStrings(indexed.entry_name, copied.entry_name);
    try std.testing.expect(copied.entry_name.ptr != indexed.entry_name.ptr);
    try std.testing.expectError(error.InvalidArtifact, summaries.summary(1));
    try std.testing.expectError(error.InvalidArtifact, summaries.summaryForWork(99));
}

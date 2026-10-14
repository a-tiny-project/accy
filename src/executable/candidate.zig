const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const artifact_product = @import("../artifact/root.zig");
const exec_product = @import("plan.zig");
const tuning_mod = @import("tuning.zig");

pub const LaunchCandidateMeasurement = tuning_mod.LaunchCandidateMeasurement;
pub const LaunchOptions = exec_product.LaunchOptions;

pub const LaunchCandidateSynchronization = enum {
    none,
    device,
    stream,
    event,
};

pub const LaunchCandidateBenchmarkOptions = struct {
    warmup: u32 = 1,
    samples: u32 = 5,
    base_options: LaunchOptions = .{},
    synchronize: LaunchCandidateSynchronization = .none,
};

pub const LaunchCandidateRecord = struct {
    kernel: artifact_product.KernelSummary,
    candidate_index: usize,
    geometry: gpu_abi.LaunchGeometry,
    candidate_score: u32,
    estimated_static_bytes_per_threadgroup: u64,
    estimated_element_ops_per_threadgroup: u64,
    median_ns: u64,
    sample_count: u32,
};

pub fn launchCandidateRecord(
    planned: artifact_product.PlannedKernel,
    candidate: artifact_product.LaunchResourceCandidate,
    measurement: LaunchCandidateMeasurement,
) gpu.BackendError!LaunchCandidateRecord {
    return .{
        .kernel = try artifact_product.summarizePlannedKernel(planned),
        .candidate_index = measurement.candidate_index,
        .geometry = candidate.geometry,
        .candidate_score = candidate.score,
        .estimated_static_bytes_per_threadgroup = candidate.estimated_static_bytes_per_threadgroup,
        .estimated_element_ops_per_threadgroup = candidate.estimated_element_ops_per_threadgroup,
        .median_ns = measurement.median_ns,
        .sample_count = measurement.sample_count,
    };
}

pub fn plannedKernelForLaunchCandidateRecord(
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    record: LaunchCandidateRecord,
) gpu.BackendError!artifact_product.PlannedKernel {
    for (artifact_plan.kernels.items) |planned| {
        if (planned.kernel_id != record.kernel.kernel_id) continue;
        if (!try launchCandidateRecordMatchesPlannedKernel(planned, record)) {
            return error.LaunchArgumentMismatch;
        }
        return planned;
    }
    return error.LaunchArgumentMismatch;
}

pub fn launchCandidateRecordMatchesPlannedKernel(
    planned: artifact_product.PlannedKernel,
    record: LaunchCandidateRecord,
) gpu.BackendError!bool {
    const planned_summary = try artifact_product.summarizePlannedKernel(planned);
    if (!artifact_product.kernelSummariesEqual(planned_summary, record.kernel)) return false;
    if (record.candidate_index >= planned.launch_resources.candidate_count) return false;
    const candidate = planned.launch_resources.candidates[record.candidate_index];
    return artifact_product.launchGeometriesEqual(candidate.geometry, record.geometry) and
        candidate.score == record.candidate_score and
        candidate.estimated_static_bytes_per_threadgroup ==
            record.estimated_static_bytes_per_threadgroup and
        candidate.estimated_element_ops_per_threadgroup ==
            record.estimated_element_ops_per_threadgroup and
        record.sample_count != 0;
}

pub fn copyKernelArtifactToAllocator(
    allocator: std.mem.Allocator,
    source: gpu.KernelArtifact,
) gpu.BackendError!gpu.KernelArtifact {
    var artifact = gpu.KernelArtifact.init(allocator, .{
        .backend = source.backend,
        .format = source.format,
        .entry_name = source.entry_name,
        .argument_count = source.argument_count,
        .scalar_argument_count = source.scalar_argument_count,
        .diagnostic_id = source.diagnostic_id,
        .interface = source.interface,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();

    switch (source.payload) {
        .text => |text| try artifact.setOwnedText(text),
        .bytes => |bytes| try artifact.setOwnedBytes(bytes),
        .words_u32 => |words| try artifact.setOwnedWords(words),
        .none, .external => return error.InvalidArtifact,
    }

    return artifact;
}

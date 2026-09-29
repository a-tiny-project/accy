const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const artifact = @import("root.zig");

pub const KernelSource = enum {
    tensor,
    kernel_call,
    choir_kernel,
};

pub const KernelSummary = struct {
    source: KernelSource,
    kernel_id: usize,
    work_item_id: usize,
    output_layout_fingerprint: u64,
    input_layout_fingerprint: u64,
    element_count: u64,
    op_count: usize,
    entry_name: []const u8,
    artifact_format: gpu.ArtifactFormat,
    artifact_payload_bytes: usize,
    compile_argument_count: u32,
    compile_required_dtype_bits: u64,
    compile_required_features: gpu_abi.Features,
    compile_required_subgroup: gpu_abi.SubgroupRequirements,
    compile_payload: artifact.PlannedKernelCompilePayload,
    compile_payload_bytes: usize,
    compile_launch: artifact.PlannedKernelCompileLaunch,
    runtime_scalar_argument_count: u32,
    launch_geometry: gpu_abi.LaunchGeometry,
    launch_candidate_count: usize,
    launch_resource_class: []const u8,
    fixed_threadgroup: bool,
    subgroup_aligned: bool,
    subgroup_size: ?u32,
    static_bytes_complete: bool,
};

pub const KernelSummaries = struct {
    allocator: std.mem.Allocator,
    items: []KernelSummary,

    pub fn deinit(self: *KernelSummaries) void {
        for (self.items) |item| {
            self.allocator.free(item.entry_name);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn len(self: *const KernelSummaries) usize {
        return self.items.len;
    }

    pub fn summary(self: *const KernelSummaries, kernel_index: usize) gpu.BackendError!KernelSummary {
        if (kernel_index >= self.items.len) return error.InvalidArtifact;
        return self.items[kernel_index];
    }

    pub fn summaryForWork(self: *const KernelSummaries, work_item_id: usize) gpu.BackendError!KernelSummary {
        for (self.items) |item| {
            if (item.work_item_id == work_item_id) return item;
        }
        return error.InvalidArtifact;
    }
};

pub fn copyKernelSummary(allocator: std.mem.Allocator, summary: KernelSummary) gpu.BackendError!KernelSummary {
    var copied = summary;
    copied.entry_name = allocator.dupe(u8, summary.entry_name) catch return error.OutOfMemory;
    return copied;
}

pub fn kernelSource(source: artifact.PlannedKernelSource) KernelSource {
    return switch (source) {
        .tensor => .tensor,
        .kernel_call => .kernel_call,
        .choir_kernel => .choir_kernel,
    };
}

pub fn artifactPayloadByteCount(kernel_artifact: gpu.KernelArtifact) gpu.BackendError!usize {
    return switch (kernel_artifact.payload) {
        .bytes => |bytes| bytes.len,
        .words_u32 => |words| words.len * @sizeOf(u32),
        .text => |text| text.len,
        .none, .external => error.InvalidArtifact,
    };
}

pub fn launchResourceClassName(class: artifact.LaunchResourceClass) []const u8 {
    return switch (class) {
        .unknown => "unknown",
        .memory_bound => "memory_bound",
        .balanced => "balanced",
        .compute_weighted => "compute_weighted",
    };
}

pub fn summarizePlannedKernel(planned: artifact.PlannedKernel) gpu.BackendError!KernelSummary {
    return .{
        .source = kernelSource(planned.compile.source),
        .kernel_id = planned.kernel_id,
        .work_item_id = planned.work_item_id,
        .output_layout_fingerprint = planned.output_layout_fingerprint,
        .input_layout_fingerprint = planned.input_layout_fingerprint,
        .element_count = planned.element_count,
        .op_count = planned.op_count,
        .entry_name = planned.artifact.entry_name,
        .artifact_format = planned.artifact.format,
        .artifact_payload_bytes = try artifactPayloadByteCount(planned.artifact),
        .compile_argument_count = planned.compile.argument_count,
        .compile_required_dtype_bits = planned.compile.required_dtypes.bits,
        .compile_required_features = planned.compile.required_features,
        .compile_required_subgroup = planned.compile.required_subgroup,
        .compile_payload = planned.compile.payload,
        .compile_payload_bytes = planned.compile.payload_byte_count,
        .compile_launch = planned.compile.launch,
        .runtime_scalar_argument_count = planned.runtime_scalar_argument_count,
        .launch_geometry = planned.launch_resources.geometry,
        .launch_candidate_count = planned.launch_resources.candidate_count,
        .launch_resource_class = launchResourceClassName(planned.launch_resources.resource_class),
        .fixed_threadgroup = planned.launch_resources.fixed_threadgroup,
        .subgroup_aligned = planned.launch_resources.subgroup_aligned,
        .subgroup_size = planned.launch_resources.subgroup_size,
        .static_bytes_complete = planned.launch_resources.static_bytes_complete,
    };
}

pub fn kernelSummariesEqual(lhs: KernelSummary, rhs: KernelSummary) bool {
    return lhs.source == rhs.source and
        lhs.kernel_id == rhs.kernel_id and
        lhs.work_item_id == rhs.work_item_id and
        lhs.output_layout_fingerprint == rhs.output_layout_fingerprint and
        lhs.input_layout_fingerprint == rhs.input_layout_fingerprint and
        lhs.element_count == rhs.element_count and
        lhs.op_count == rhs.op_count and
        std.mem.eql(u8, lhs.entry_name, rhs.entry_name) and
        lhs.artifact_format == rhs.artifact_format and
        lhs.artifact_payload_bytes == rhs.artifact_payload_bytes and
        lhs.compile_argument_count == rhs.compile_argument_count and
        lhs.compile_required_dtype_bits == rhs.compile_required_dtype_bits and
        std.meta.eql(lhs.compile_required_features, rhs.compile_required_features) and
        std.meta.eql(lhs.compile_required_subgroup, rhs.compile_required_subgroup) and
        lhs.compile_payload == rhs.compile_payload and
        lhs.compile_payload_bytes == rhs.compile_payload_bytes and
        lhs.compile_launch == rhs.compile_launch and
        lhs.runtime_scalar_argument_count == rhs.runtime_scalar_argument_count and
        launchGeometriesEqual(lhs.launch_geometry, rhs.launch_geometry) and
        lhs.launch_candidate_count == rhs.launch_candidate_count and
        std.mem.eql(u8, lhs.launch_resource_class, rhs.launch_resource_class) and
        lhs.fixed_threadgroup == rhs.fixed_threadgroup and
        lhs.subgroup_aligned == rhs.subgroup_aligned and
        lhs.subgroup_size == rhs.subgroup_size and
        lhs.static_bytes_complete == rhs.static_bytes_complete;
}

pub fn launchGeometriesEqual(lhs: gpu_abi.LaunchGeometry, rhs: gpu_abi.LaunchGeometry) bool {
    return lhs.grid[0] == rhs.grid[0] and
        lhs.grid[1] == rhs.grid[1] and
        lhs.grid[2] == rhs.grid[2] and
        lhs.threadgroup[0] == rhs.threadgroup[0] and
        lhs.threadgroup[1] == rhs.threadgroup[1] and
        lhs.threadgroup[2] == rhs.threadgroup[2] and
        lhs.dynamic_shared_memory_bytes == rhs.dynamic_shared_memory_bytes;
}

fn testKernelSummary() KernelSummary {
    return .{
        .source = .tensor,
        .kernel_id = 7,
        .work_item_id = 3,
        .output_layout_fingerprint = 11,
        .input_layout_fingerprint = 13,
        .element_count = 1024,
        .op_count = 4,
        .entry_name = "accy_test_kernel",
        .artifact_format = .cuda_ptx,
        .artifact_payload_bytes = 128,
        .compile_argument_count = 3,
        .compile_required_dtype_bits = gpu.DTypeSet.init(&.{ .f32, .i32 }).bits,
        .compile_required_features = .{},
        .compile_required_subgroup = .{},
        .compile_payload = .text,
        .compile_payload_bytes = 96,
        .compile_launch = .generic,
        .runtime_scalar_argument_count = 0,
        .launch_geometry = .{
            .grid = .{ 8, 2, 1 },
            .threadgroup = .{ 128, 1, 1 },
            .dynamic_shared_memory_bytes = 256,
        },
        .launch_candidate_count = 2,
        .launch_resource_class = "balanced",
        .fixed_threadgroup = false,
        .subgroup_aligned = true,
        .subgroup_size = 32,
        .static_bytes_complete = true,
    };
}

test "artifact kernel summary equality includes compile contract" {
    const base = testKernelSummary();
    try std.testing.expect(kernelSummariesEqual(base, testKernelSummary()));

    var changed = testKernelSummary();
    changed.compile_argument_count += 1;
    try std.testing.expect(!kernelSummariesEqual(base, changed));

    changed = testKernelSummary();
    changed.compile_required_dtype_bits ^= gpu.DTypeSet.init(&.{.f16}).bits;
    try std.testing.expect(!kernelSummariesEqual(base, changed));

    changed = testKernelSummary();
    changed.compile_required_features = .{ .tensor_cores = true };
    try std.testing.expect(!kernelSummariesEqual(base, changed));

    changed = testKernelSummary();
    changed.compile_required_subgroup = .{ .supported = true, .shuffle = true };
    try std.testing.expect(!kernelSummariesEqual(base, changed));

    changed = testKernelSummary();
    changed.compile_payload = .bytes;
    try std.testing.expect(!kernelSummariesEqual(base, changed));

    changed = testKernelSummary();
    changed.compile_payload_bytes += 1;
    try std.testing.expect(!kernelSummariesEqual(base, changed));

    changed = testKernelSummary();
    changed.compile_launch = .dot_general;
    try std.testing.expect(!kernelSummariesEqual(base, changed));

    changed = testKernelSummary();
    changed.runtime_scalar_argument_count += 1;
    try std.testing.expect(!kernelSummariesEqual(base, changed));

    changed = testKernelSummary();
    changed.launch_geometry.dynamic_shared_memory_bytes += 1;
    try std.testing.expect(!kernelSummariesEqual(base, changed));
}

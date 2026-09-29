const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const records = @import("root.zig");

pub const CompileOptions = struct {
    cpu_vector_width: ?u32 = null,
};

pub const BackendTargetProfile = struct {
    backend_kind: gpu.BackendKind,
    artifact_format: gpu.ArtifactFormat,
    math_tier: gpu.BackendMathTier = .exact,
    dtype_bits: u64 = 0,
    feature_bits: u64 = 0,

    pub fn init(
        caps: gpu.BackendCapabilities,
        backend_kind: gpu.BackendKind,
        artifact_format: gpu.ArtifactFormat,
    ) gpu.BackendError!BackendTargetProfile {
        return initWithMathTier(caps, backend_kind, artifact_format, .exact);
    }

    pub fn initWithMathTier(
        caps: gpu.BackendCapabilities,
        backend_kind: gpu.BackendKind,
        artifact_format: gpu.ArtifactFormat,
        math_tier: gpu.BackendMathTier,
    ) gpu.BackendError!BackendTargetProfile {
        if (!caps.supportsArtifactFormat(artifact_format)) return error.UnsupportedArtifactFormat;
        if (!mathTierSupported(caps, backend_kind, artifact_format, math_tier)) return error.CapabilityMismatch;
        return .{
            .backend_kind = backend_kind,
            .artifact_format = artifact_format,
            .math_tier = math_tier,
            .dtype_bits = caps.dtypes.bits,
            .feature_bits = featureBits(caps.features),
        };
    }

    pub fn dtypes(self: BackendTargetProfile) gpu.DTypeSet {
        return .{ .bits = self.dtype_bits };
    }

    pub fn supportsDType(self: BackendTargetProfile, element_type: gpu_abi.DType) bool {
        return self.dtypes().contains(element_type);
    }

    pub fn supportsFeaturesFrom(self: BackendTargetProfile, caps: gpu.BackendCapabilities) bool {
        return (featureBits(caps.features) & self.feature_bits) == self.feature_bits;
    }

    pub fn isSupportedBy(self: BackendTargetProfile, caps: gpu.BackendCapabilities) bool {
        return caps.supportsArtifactFormat(self.artifact_format) and
            caps.dtypes.containsAll(self.dtypes()) and
            self.supportsFeaturesFrom(caps) and
            mathTierSupported(caps, self.backend_kind, self.artifact_format, self.math_tier);
    }

    pub fn eql(self: BackendTargetProfile, other: BackendTargetProfile) bool {
        return self.backend_kind == other.backend_kind and
            self.artifact_format == other.artifact_format and
            self.math_tier == other.math_tier and
            self.dtype_bits == other.dtype_bits and
            self.feature_bits == other.feature_bits;
    }
};

pub const Abi = struct {
    argument_count: u32,
    static_arguments: []const gpu_abi.ScalarArgument,
    launch: ?gpu_abi.LaunchGeometry,
    compile_options: CompileOptions,
};

pub const Kernel = struct {
    lowered: records.kernel.Lowered,
    work_dtype: gpu_abi.DType,
    element_count: u64,
    required_dtype_bits: u64,
    required_features: gpu_abi.Features,
    required_subgroup: gpu_abi.SubgroupRequirements,
    runtime_scalar_argument_count: u32,
    abi: ?Abi,
};

pub const Record = struct {
    profile: ?BackendTargetProfile,
    math_tier: gpu.BackendMathTier,
    generated_scan_schedules: ?[]const u8,
    generated_row_pipeline_schedules: ?[]const u8,
    kernels: []const Kernel,
};

pub fn validate(allocator: std.mem.Allocator, value: Record, parent: records.kernel.Record) !void {
    if (value.kernels.len != parent.generated.kernels.len) return error.InvalidStageRecord;
    const tier = if (value.profile) |profile| profile.math_tier else .exact;
    if (value.math_tier != tier) return error.InvalidStageRecord;
    var work = std.AutoHashMapUnmanaged(usize, bool).empty;
    defer work.deinit(allocator);
    const count = std.math.cast(u32, parent.generated.kernels.len) orelse
        return error.InvalidStageRecord;
    try work.ensureTotalCapacity(allocator, count);
    for (parent.generated.kernels) |kernel| work.putAssumeCapacity(kernel.work_item_id, false);
    for (value.kernels) |kernel| {
        const seen = work.getPtr(kernel.lowered.work_item_id) orelse
            return error.InvalidStageRecord;
        if (seen.*) return error.InvalidStageRecord;
        seen.* = true;
        const arguments = kernel.lowered.program.params.len;
        if (kernel.lowered.argument_count != arguments or
            kernel.runtime_scalar_argument_count != try runtimeScalarCount(kernel.lowered.program)) return error.InvalidStageRecord;
        if ((value.profile == null) != (kernel.abi == null)) return error.InvalidStageRecord;
        if (kernel.abi) |abi| {
            if (abi.argument_count < arguments or
                abi.static_arguments.len != abi.argument_count - arguments)
            {
                return error.InvalidStageRecord;
            }
        }
    }
}

fn runtimeScalarCount(program: records.program.Record) !u32 {
    var count: u32 = 0;
    for (program.params) |param| {
        switch (param) {
            .scalar => count = std.math.add(u32, count, 1) catch
                return error.InvalidStageRecord,
            .buffer => {},
        }
    }
    return count;
}

fn featureBits(features: gpu_abi.Features) u64 {
    var bits: u64 = 0;
    if (features.atomic_i32) bits |= 1 << 0;
    if (features.atomic_u32) bits |= 1 << 1;
    if (features.atomic_index) bits |= 1 << 2;
    if (features.atomic_f32_add_device) bits |= 1 << 3;
    if (features.atomic_f32_add_shared) bits |= 1 << 4;
    if (features.unsupported_atomic) bits |= 1 << 5;
    if (features.async_copy) bits |= 1 << 6;
    if (features.tensor_cores) bits |= 1 << 7;
    if (features.cooperative_matrix) bits |= 1 << 8;
    if (features.dynamic_shared_memory) bits |= 1 << 9;
    if (features.indirect_launch) bits |= 1 << 10;
    return bits;
}

fn mathTierSupported(
    caps: gpu.BackendCapabilities,
    backend_kind: gpu.BackendKind,
    artifact_format: gpu.ArtifactFormat,
    math_tier: gpu.BackendMathTier,
) bool {
    return switch (math_tier) {
        .exact => true,
        .tf32_tensor => backend_kind == .cuda and artifact_format == .cuda_ptx and caps.features.tensor_cores,
    };
}

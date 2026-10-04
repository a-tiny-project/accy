const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const model = @import("model/root.zig");
const plan_mod = @import("plan.zig");
const preparation = @import("../preparation/root.zig");

pub fn artifactPlan(value: *const plan_mod.BackendArtifactPlan) u64 {
    var hasher = choir.product.incremental.FingerprintBuilder{};
    hasher.updateBytes("accy.artifact.plan");
    hashBackendTargetProfile(&hasher, value.target_profile);
    hashU64(&hasher, @backingInt(value.backend_kind));
    hashU64(&hasher, @backingInt(value.format));
    hashU64(&hasher, value.slots.len);
    for (value.slots) |slot| hashPlannedSlot(&hasher, slot);
    hashU64(&hasher, value.input_slot_ids.len);
    for (value.input_slot_ids) |slot_id| hashU64(&hasher, slot_id);
    hashU64(&hasher, value.output_slot_ids.len);
    for (value.output_slot_ids) |slot_id| hashU64(&hasher, slot_id);
    hashU64(&hasher, value.kernels.items.len);
    for (value.kernels.items) |kernel| hashPlannedKernel(&hasher, kernel);
    hashU64(&hasher, value.total_kernel_ops);
    hashU64(&hasher, value.total_static_bytes);
    return hasher.finish();
}

pub fn kernelCallRegistry(value: ?*const model.KernelCallRegistry) u64 {
    var hasher = choir.product.incremental.FingerprintBuilder{};
    hasher.updateBytes("accy.artifact.kernel_call_registry");
    hashU64(&hasher, @intFromBool(value != null));
    const registry = value orelse return hasher.finish();
    hashU64(&hasher, registry.entries.len);
    for (registry.entries) |entry| hashKernelCallArtifact(&hasher, entry);
    return hasher.finish();
}

pub fn launchResourcePlan(value: plan_mod.LaunchResourcePlan) u64 {
    var hasher = choir.product.incremental.FingerprintBuilder{};
    hasher.updateBytes("accy.artifact.launch_resource_plan");
    hashLaunchResourcePlan(&hasher, value);
    return hasher.finish();
}

fn hashBackendTargetProfile(
    hasher: *choir.product.incremental.FingerprintBuilder,
    profile: anytype,
) void {
    hashU64(hasher, @backingInt(profile.backend_kind));
    hashU64(hasher, @backingInt(profile.artifact_format));
    hashU64(hasher, @backingInt(profile.math_tier));
    hashU64(hasher, profile.dtype_bits);
    hashU64(hasher, profile.feature_bits);
}

fn hashPlannedSlot(
    hasher: *choir.product.incremental.FingerprintBuilder,
    slot: plan_mod.PlannedSlot,
) void {
    hashU64(hasher, slot.slot_id);
    hashBufferRole(hasher, slot.role);
    hashU64(hasher, @backingInt(slot.dtype));
    hashU64(hasher, @backingInt(slot.memory_space));
    hashU64(hasher, @backingInt(slot.memory_access));
    hashU64(hasher, @backingInt(slot.boundary_transfer));
    hashU64(hasher, @backingInt(slot.layout_kind));
    hashU64(hasher, slot.dims.len);
    for (slot.dims) |dim| hashU64(hasher, @bitCast(dim));
    hashOptionalU64Slice(hasher, slot.element_strides);
    hashU64(hasher, slot.minor_to_major.len);
    for (slot.minor_to_major) |minor| hashU64(hasher, minor);
    hashOptionalU64(hasher, slot.element_count);
    hashOptionalU64(hasher, slot.byte_size);
    hashU64(hasher, slot.alignment);
    hashU64(hasher, @intFromBool(slot.contiguous));
    hashU64(hasher, @intFromBool(slot.static_layout));
    hashU64(hasher, slot.layout_fingerprint);
    hashBytes(hasher, slot.constant_payload);
}

fn hashBufferRole(hasher: *choir.product.incremental.FingerprintBuilder, role: anytype) void {
    hashU64(hasher, @intFromBool(role.input));
    hashU64(hasher, @intFromBool(role.output));
    hashU64(hasher, @intFromBool(role.temporary));
    hashU64(hasher, @intFromBool(role.constant));
}

fn hashPlannedKernel(
    hasher: *choir.product.incremental.FingerprintBuilder,
    kernel: plan_mod.PlannedKernel,
) void {
    hashPlannedKernelCompile(hasher, kernel.compile);
    hashU64(hasher, kernel.kernel_id);
    hashU64(hasher, kernel.work_item_id);
    hashU64(hasher, kernel.output_slot_id);
    hashU64(hasher, kernel.input_slot_ids.len);
    for (kernel.input_slot_ids) |slot_id| hashU64(hasher, slot_id);
    hashU64(hasher, kernel.output_layout_fingerprint);
    hashU64(hasher, kernel.input_layout_fingerprint);
    hashU64(hasher, kernel.element_count);
    hashU64(hasher, kernel.op_count);
    hashScheduleResourceEstimate(hasher, kernel.resources);
    hashKernelArtifact(hasher, kernel.artifact);
    hashLaunchResourcePlan(hasher, kernel.launch_resources);
    hashOptionalKernelCallLaunch(hasher, kernel.kernel_call_launch);
    hashU64(hasher, @backingInt(kernel.element_count_argument));
    hashU64(hasher, kernel.element_count_argument_value);
    hashU64(hasher, kernel.runtime_scalar_argument_count);
    hashU64(hasher, kernel.runtime_scalar_defaults.len);
    for (kernel.runtime_scalar_defaults) |argument| hashKernelScalarArgument(hasher, argument);
    hashU64(hasher, kernel.static_arguments.len);
    for (kernel.static_arguments) |argument| hashKernelScalarArgument(hasher, argument);
}

fn hashPlannedKernelCompile(
    hasher: *choir.product.incremental.FingerprintBuilder,
    compile: plan_mod.PlannedKernelCompileContract,
) void {
    hashU64(hasher, @backingInt(compile.source));
    hashU64(hasher, @backingInt(compile.launch));
    hashU64(hasher, @backingInt(compile.format));
    hashBytes(hasher, compile.entry_name);
    hashU64(hasher, compile.argument_count);
    hashU64(hasher, compile.required_dtypes.bits);
    hashAcceleratorFeatures(hasher, compile.required_features);
    hashSubgroupRequirements(hasher, compile.required_subgroup);
    hashOptionalU64(hasher, compile.shape_family_fingerprint);
    hashU64(hasher, @backingInt(compile.payload));
    hashU64(hasher, compile.payload_byte_count);
}

fn hashAcceleratorFeatures(
    hasher: *choir.product.incremental.FingerprintBuilder,
    features: gpu_abi.Features,
) void {
    hashU64(hasher, @intFromBool(features.atomic_i32));
    hashU64(hasher, @intFromBool(features.atomic_u32));
    hashU64(hasher, @intFromBool(features.atomic_index));
    hashU64(hasher, @intFromBool(features.atomic_f32_add_device));
    hashU64(hasher, @intFromBool(features.atomic_f32_add_shared));
    hashU64(hasher, @intFromBool(features.unsupported_atomic));
    hashU64(hasher, @intFromBool(features.async_copy));
    hashU64(hasher, @intFromBool(features.tensor_cores));
    hashU64(hasher, @intFromBool(features.cooperative_matrix));
    hashU64(hasher, @intFromBool(features.dynamic_shared_memory));
    hashU64(hasher, @intFromBool(features.indirect_launch));
}

fn hashSubgroupRequirements(
    hasher: *choir.product.incremental.FingerprintBuilder,
    requirements: gpu_abi.SubgroupRequirements,
) void {
    hashU64(hasher, @intFromBool(requirements.supported));
    hashU64(hasher, requirements.size_min);
    hashU64(hasher, requirements.size_max);
    hashU64(hasher, @intFromBool(requirements.shuffle));
    hashU64(hasher, @intFromBool(requirements.ballot));
    hashU64(hasher, @intFromBool(requirements.vote));
    hashU64(hasher, @intFromBool(requirements.arithmetic));
    hashU64(hasher, @intFromBool(requirements.scan));
}

fn hashScheduleResourceEstimate(
    hasher: *choir.product.incremental.FingerprintBuilder,
    resources: anytype,
) void {
    hashU64(hasher, resources.element_count);
    hashU64(hasher, resources.element_size);
    hashU64(hasher, resources.op_count);
    hashU64(hasher, resources.external_input_value_count);
    hashU64(hasher, resources.external_operand_count);
    hashU64(hasher, resources.chain_operand_count);
    hashU64(hasher, resources.estimated_element_ops);
    hashU64(hasher, resources.static_read_bytes);
    hashU64(hasher, resources.static_write_bytes);
    hashU64(hasher, resources.static_total_bytes);
    hashU64(hasher, @intFromBool(resources.static_bytes_complete));
}

fn hashKernelArtifact(
    hasher: *choir.product.incremental.FingerprintBuilder,
    artifact: gpu.KernelArtifact,
) void {
    hashU64(hasher, @backingInt(artifact.backend));
    hashU64(hasher, @backingInt(artifact.format));
    hashBytes(hasher, artifact.entry_name);
    hashU64(hasher, artifact.argument_count);
    hashOptionalBytes(hasher, artifact.diagnostic_id);
    hashArtifactPayload(hasher, artifact.payload);
    hashU64(hasher, @backingInt(artifact.payload_ownership));
}

fn hashArtifactPayload(
    hasher: *choir.product.incremental.FingerprintBuilder,
    payload: gpu.ArtifactPayload,
) void {
    hashU64(hasher, @backingInt(payload));
    switch (payload) {
        .none => {},
        .bytes => |bytes| hashBytes(hasher, bytes),
        .text => |text| hashBytes(hasher, text),
        .words_u32 => |words| {
            hashU64(hasher, words.len);
            for (words) |word| hashU64(hasher, word);
        },
        .external => |external| {
            hashU64(hasher, @intFromPtr(external.ptr));
            hashU64(hasher, @intFromBool(external.deinit_fn != null));
        },
    }
}

fn hashCompilePayload(
    hasher: *choir.product.incremental.FingerprintBuilder,
    payload: gpu.CompilePayload,
) void {
    hashU64(hasher, @backingInt(payload));
    switch (payload) {
        .none => {},
        .bytes => |bytes| hashBytes(hasher, bytes),
        .text => |text| hashBytes(hasher, text),
        .words_u32 => |words| {
            hashU64(hasher, words.len);
            for (words) |word| hashU64(hasher, word);
        },
    }
}

fn hashKernelCallArtifact(
    hasher: *choir.product.incremental.FingerprintBuilder,
    artifact: model.KernelCallArtifact,
) void {
    hashBytes(hasher, artifact.target);
    hashU64(hasher, artifact.version);
    hashU64(hasher, @backingInt(artifact.format));
    hashBytes(hasher, artifact.entry_name);
    hashU64(hasher, artifact.argument_count);
    hashOptionalU64(hasher, artifact.shape_family_fingerprint);
    hashOptionalKernelCallShapeProfile(hasher, artifact.shape_profile);
    hashU64(hasher, artifact.required_dtypes.bits);
    hashAcceleratorFeatures(hasher, artifact.required_features);
    hashSubgroupRequirements(hasher, artifact.required_subgroup);
    hashCompilePayload(hasher, artifact.payload);
    hashKernelCallLaunch(hasher, artifact.launch);
    hashU64(hasher, @backingInt(artifact.element_count_argument));
    hashU64(hasher, artifact.runtime_scalar_argument_count);
    hashU64(hasher, artifact.static_arguments.len);
    for (artifact.static_arguments) |argument| hashKernelScalarArgument(hasher, argument);
}

fn hashOptionalKernelCallShapeProfile(
    hasher: *choir.product.incremental.FingerprintBuilder,
    profile: ?model.KernelCallShapeProfile,
) void {
    hashU64(hasher, @intFromBool(profile != null));
    if (profile) |value| {
        hashBytes(hasher, value.name);
        hashU64(hasher, value.fingerprint);
        hashU64(hasher, value.dimensions.len);
        for (value.dimensions) |dimension| {
            hashBytes(hasher, dimension.name);
            hashU64(hasher, dimension.runtime_scalar_argument_index);
            hashShapeBounds(hasher, dimension.bounds);
        }
    }
}

fn hashShapeBounds(hasher: *choir.product.incremental.FingerprintBuilder, bounds: anytype) void {
    hashOptionalU64(hasher, bounds.min);
    hashOptionalU64(hasher, bounds.opt);
    hashOptionalU64(hasher, bounds.max);
}

fn hashOptionalKernelCallLaunch(
    hasher: *choir.product.incremental.FingerprintBuilder,
    launch: ?model.KernelCallLaunch,
) void {
    hashU64(hasher, @intFromBool(launch != null));
    if (launch) |value| hashKernelCallLaunch(hasher, value);
}

fn hashKernelCallLaunch(
    hasher: *choir.product.incremental.FingerprintBuilder,
    launch: model.KernelCallLaunch,
) void {
    hashU64(hasher, @backingInt(launch));
    switch (launch) {
        .derived => |derived| hashKernelCallDerivedLaunch(hasher, derived),
        .fixed => |geometry| hashLaunchGeometry(hasher, geometry),
    }
}

fn hashKernelCallDerivedLaunch(
    hasher: *choir.product.incremental.FingerprintBuilder,
    launch: model.KernelCallDerivedLaunch,
) void {
    for (launch.grid) |axis| hashKernelCallDerivedLaunchAxis(hasher, axis);
    for (launch.threadgroup) |extent| hashU64(hasher, extent);
    hashU64(hasher, launch.dynamic_shared_memory_bytes);
}

fn hashKernelCallDerivedLaunchAxis(
    hasher: *choir.product.incremental.FingerprintBuilder,
    axis: model.KernelCallDerivedLaunchAxis,
) void {
    hashU64(hasher, @backingInt(axis));
    switch (axis) {
        .fixed => |extent| hashU64(hasher, extent),
        .runtime_u32_ceil_div => |runtime| {
            hashU64(hasher, runtime.argument_index);
            hashU64(hasher, runtime.divisor);
        },
    }
}

fn hashLaunchResourcePlan(
    hasher: *choir.product.incremental.FingerprintBuilder,
    plan: plan_mod.LaunchResourcePlan,
) void {
    hashU64(hasher, @backingInt(plan.format));
    hashU64(hasher, plan.element_count);
    hashLaunchGeometry(hasher, plan.geometry);
    hashOptionalU32(hasher, plan.subgroup_size);
    hashU64(hasher, @intFromBool(plan.subgroup_aligned));
    hashU64(hasher, @intFromBool(plan.fixed_threadgroup));
    hashU64(hasher, @backingInt(plan.resource_class));
    hashU64(hasher, plan.element_ops_per_kib);
    hashU64(hasher, plan.estimated_static_bytes_per_threadgroup);
    hashU64(hasher, plan.estimated_element_ops_per_threadgroup);
    hashU64(hasher, @intFromBool(plan.static_bytes_complete));
    hashLaunchTilePlan(hasher, plan.tile);
    hashU64(hasher, plan.candidate_count);
    for (plan.candidates[0..plan.candidate_count]) |candidate| {
        hashLaunchResourceCandidate(hasher, candidate);
    }
}

fn hashLaunchResourceCandidate(
    hasher: *choir.product.incremental.FingerprintBuilder,
    candidate: plan_mod.LaunchResourceCandidate,
) void {
    hashLaunchGeometry(hasher, candidate.geometry);
    hashU64(hasher, candidate.score);
    hashU64(hasher, candidate.estimated_static_bytes_per_threadgroup);
    hashU64(hasher, candidate.estimated_element_ops_per_threadgroup);
    hashLaunchTilePlan(hasher, candidate.tile);
}

fn hashLaunchGeometry(
    hasher: *choir.product.incremental.FingerprintBuilder,
    geometry: gpu_abi.LaunchGeometry,
) void {
    for (geometry.grid) |value| hashU64(hasher, value);
    for (geometry.threadgroup) |value| hashU64(hasher, value);
    hashU64(hasher, geometry.dynamic_shared_memory_bytes);
}

fn hashLaunchTilePlan(
    hasher: *choir.product.incremental.FingerprintBuilder,
    tile: plan_mod.LaunchTilePlan,
) void {
    hashU64(hasher, @backingInt(tile.kind));
    hashU64(hasher, tile.m);
    hashU64(hasher, tile.n);
    hashU64(hasher, tile.k);
    hashU64(hasher, tile.batch);
    hashOptionalDType(hasher, tile.input_dtype);
    hashOptionalDType(hasher, tile.output_dtype);
    hashU64(hasher, tile.input_tile_bytes);
    hashU64(hasher, tile.output_tile_bytes);
    hashU64(hasher, tile.scratch_memory_bytes);
    hashU64(hasher, @backingInt(tile.reduction_kind));
    hashU64(hasher, tile.reduction_rank);
    hashU64(hasher, tile.reduction_axis);
    hashU64(hasher, tile.reduction_extent);
}

fn hashKernelScalarArgument(
    hasher: *choir.product.incremental.FingerprintBuilder,
    argument: gpu_abi.ScalarArgument,
) void {
    hashU64(hasher, @backingInt(argument));
    switch (argument) {
        .i32 => |value| hashU64(hasher, @as(u32, @bitCast(value))),
        .u32 => |value| hashU64(hasher, value),
        .i64 => |value| hashU64(hasher, @bitCast(value)),
        .u64 => |value| hashU64(hasher, value),
        .f32 => |value| hashU64(hasher, @as(u32, @bitCast(value))),
        .f64 => |value| hashU64(hasher, @bitCast(value)),
    }
}

fn hashOptionalDType(
    hasher: *choir.product.incremental.FingerprintBuilder,
    dtype: ?gpu_abi.DType,
) void {
    hasher.updateBool(dtype != null);
    if (dtype) |value| hashU64(hasher, @backingInt(value));
}

fn hashOptionalU32(hasher: *choir.product.incremental.FingerprintBuilder, value: ?u32) void {
    hasher.updateBool(value != null);
    if (value) |payload| hasher.updateU32(payload);
}

fn hashOptionalU64(hasher: *choir.product.incremental.FingerprintBuilder, value: ?u64) void {
    hasher.updateOptionalU64(value);
}

fn hashOptionalU64Slice(
    hasher: *choir.product.incremental.FingerprintBuilder,
    value: ?[]const u64,
) void {
    hasher.updateOptionalU64Slice(value);
}

fn hashOptionalBytes(
    hasher: *choir.product.incremental.FingerprintBuilder,
    value: ?[]const u8,
) void {
    hasher.updateBool(value != null);
    if (value) |bytes| hashBytes(hasher, bytes);
}

fn hashBytes(hasher: *choir.product.incremental.FingerprintBuilder, bytes: []const u8) void {
    hasher.updateBytes(bytes);
}

fn hashU64(hasher: *choir.product.incremental.FingerprintBuilder, value: u64) void {
    hasher.updateU64(value);
}

fn standalonePlanWithShapeFamilyFingerprint(
    allocator: std.mem.Allocator,
    family_fingerprint: u64,
) !plan_mod.BackendArtifactPlan {
    var plan = plan_mod.BackendArtifactPlan.init(allocator, .{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .dtype_bits = gpu.DTypeSet.init(&.{.f32}).bits,
    });
    errdefer plan.deinit();

    var artifact = try gpu.KernelArtifact.init(allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = "kernel_call",
        .argument_count = 3,
    });
    var artifact_owned = true;
    errdefer if (artifact_owned) artifact.deinit();
    try artifact.setOwnedText("// ptx");

    var compile = try plan_mod.PlannedKernelCompileContract.init(
        allocator,
        .kernel_call,
        .kernel_call,
        .cuda_ptx,
        "kernel_call",
        3,
        gpu.DTypeSet.init(&.{.f32}),
        .{},
        .{},
        family_fingerprint,
        .{ .text = "// ptx" },
    );
    var compile_owned = true;
    errdefer if (compile_owned) compile.deinit(allocator);

    try plan.addStandaloneKernel(
        artifact,
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

    return plan;
}

const random = @import("../root.zig");
const types = @import("types.zig");
const runtime = @import("runtime.zig");

const base = random.base;
const std = base.std;
const artifact_product = base.artifact_product;
const entry = base.entry;
const kernel = base.kernel;

const PhiloxKeySplit = types.PhiloxKeySplit;
const PhiloxKeyUniform = types.PhiloxKeyUniform;
const PhiloxKeyCounterUniform = types.PhiloxKeyCounterUniform;
const PhiloxKeySplitRuntimeFamily = runtime.PhiloxKeySplitRuntimeFamily;
const PhiloxKeyUniformRuntimeFamilyF32 = runtime.PhiloxKeyUniformRuntimeFamilyF32;
const PhiloxKeyUniformRuntimeFamilyI32 = runtime.PhiloxKeyUniformRuntimeFamilyI32;
const PhiloxKeyCounterUniformRuntimeFamilyF32 = runtime.PhiloxKeyCounterUniformRuntimeFamilyF32;
const PhiloxKeyCounterUniformRuntimeFamilyI32 = runtime.PhiloxKeyCounterUniformRuntimeFamilyI32;
const philox_key_split_family_version = types.philox_key_split_family_version;
const philox_key_uniform_family_version = types.philox_key_uniform_family_version;
const philox_key_counter_uniform_family_version = types.philox_key_counter_uniform_family_version;
const philoxKeySplitFamilyTarget = @import("names.zig").philoxKeySplitFamilyTarget;
const philoxKeySplitFamilyEntryName = @import("names.zig").philoxKeySplitFamilyEntryName;
const philoxKeyUniformFamilyTarget = @import("names.zig").philoxKeyUniformFamilyTarget;
const philoxKeyUniformFamilyEntryName = @import("names.zig").philoxKeyUniformFamilyEntryName;
const philoxKeyCounterUniformFamilyTarget = @import(
    "names.zig",
).philoxKeyCounterUniformFamilyTarget;
const philoxKeyCounterUniformFamilyEntryName = @import(
    "names.zig",
).philoxKeyCounterUniformFamilyEntryName;
const profile = @import("profile.zig");
const randomFoldDerivedLaunch = base.randomFoldDerivedLaunch;

pub fn createPhiloxKeySplitFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: PhiloxKeySplit,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try philoxKeySplitFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try philoxKeySplitFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try profile.philoxKeySplitFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = profile.philoxKeySplitShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "philox_key_split",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = try PhiloxKeySplitRuntimeFamily.buildNamed(
        allocator,
        options.limits,
        entry_name,
        instance,
    );
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = philox_key_split_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try randomFoldDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createPhiloxKeyUniformFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: PhiloxKeyUniform,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try philoxKeyUniformFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try philoxKeyUniformFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try profile.philoxKeyUniformFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = profile.philoxKeyUniformShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "philox_key_uniform",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try PhiloxKeyUniformRuntimeFamilyF32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .i32 => try PhiloxKeyUniformRuntimeFamilyI32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = philox_key_uniform_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try randomFoldDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

pub fn createPhiloxKeyCounterUniformFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: PhiloxKeyCounterUniform,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try philoxKeyCounterUniformFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try philoxKeyCounterUniformFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try profile.philoxKeyCounterUniformFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = profile.philoxKeyCounterUniformShapeProfileDimensions(
        instance,
    );
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "philox_key_counter_uniform",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try PhiloxKeyCounterUniformRuntimeFamilyF32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .i32 => try PhiloxKeyCounterUniformRuntimeFamilyI32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = philox_key_counter_uniform_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try randomFoldDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            1
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

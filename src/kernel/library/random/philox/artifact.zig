const random = @import("../root.zig");

const base = random.base;
const block = random.block;
const model = @import("model.zig");
const runtime = @import("runtime.zig");

const std = base.std;
const artifact_product = base.artifact_product;
const entry = base.entry;
const kernel = base.kernel;

const Philox = model.Philox;
const PhiloxRuntimeFamilyF32 = runtime.PhiloxRuntimeFamilyF32;
const PhiloxRuntimeFamilyI32 = runtime.PhiloxRuntimeFamilyI32;
const philox_lanes = block.philox_lanes;
const philox_family_version = model.philox_family_version;
const philoxFamilyTarget = model.philoxFamilyTarget;
const philoxFamilyEntryName = model.philoxFamilyEntryName;
const philoxFamilyFingerprint = model.philoxFamilyFingerprint;
const philoxShapeProfileDimensions = model.philoxShapeProfileDimensions;
const randomDerivedLaunch = base.randomDerivedLaunch;

pub fn createPhiloxFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: Philox,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try philoxFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try philoxFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try philoxFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = philoxShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "philox",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try PhiloxRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .i32 => try PhiloxRuntimeFamilyI32.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = philox_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try randomDerivedLaunch(instance.threads, philox_lanes),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 3 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

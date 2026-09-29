const random = @import("../root.zig");

const base = random.base;
const block = random.block;
const model = @import("model.zig");
const runtime = @import("runtime.zig");

const std = base.std;
const artifact_product = base.artifact_product;
const entry = base.entry;
const kernel = base.kernel;

const Threefry = model.Threefry;
const ThreefryRuntimeFamilyF32 = runtime.ThreefryRuntimeFamilyF32;
const ThreefryRuntimeFamilyI32 = runtime.ThreefryRuntimeFamilyI32;
const threefry_lanes = block.threefry_lanes;
const threefry_family_version = model.threefry_family_version;
const threefryFamilyTarget = model.threefryFamilyTarget;
const threefryFamilyEntryName = model.threefryFamilyEntryName;
const threefryFamilyFingerprint = model.threefryFamilyFingerprint;
const threefryShapeProfileDimensions = model.threefryShapeProfileDimensions;
const randomDerivedLaunch = base.randomDerivedLaunch;

pub fn createThreefryFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: Threefry,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try threefryFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try threefryFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try threefryFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = threefryShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "threefry",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try ThreefryRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .i32 => try ThreefryRuntimeFamilyI32.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = threefry_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try randomDerivedLaunch(instance.threads, threefry_lanes),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 3 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

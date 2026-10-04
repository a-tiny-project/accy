const random = @import("../root.zig");
const model = @import("model.zig");
const runtime = @import("runtime.zig");

const base = random.base;
const std = base.std;
const artifact_product = base.artifact_product;
const entry = base.entry;
const kernel = base.kernel;

const Feistel = model.Feistel;
const FeistelRuntimeFamilyI32 = runtime.FeistelRuntimeFamilyI32;
const feistel_family_version = model.feistel_family_version;
const feistelFamilyTarget = model.feistelFamilyTarget;
const feistelFamilyEntryName = model.feistelFamilyEntryName;
const feistelFamilyFingerprint = model.feistelFamilyFingerprint;
const feistelShapeProfileDimensions = model.feistelShapeProfileDimensions;
const feistelInstanceValid = model.feistelInstanceValid;
const randomFoldDerivedLaunch = base.randomFoldDerivedLaunch;

pub fn createFeistelFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: Feistel,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!feistelInstanceValid(instance)) return error.UnsupportedExtent;
    const target = try feistelFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try feistelFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try feistelFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = feistelShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "feistel",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .i32 => try FeistelRuntimeFamilyI32.buildNamed(
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
        .version = feistel_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try randomFoldDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            3
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

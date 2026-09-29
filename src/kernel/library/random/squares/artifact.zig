const random = @import("../root.zig");
const model = @import("model.zig");
const runtime = @import("runtime.zig");

const base = random.base;
const std = base.std;
const artifact_product = base.artifact_product;
const entry = base.entry;
const kernel = base.kernel;

const Squares = model.Squares;
const SquaresRuntimeFamilyF32 = runtime.SquaresRuntimeFamilyF32;
const SquaresRuntimeFamilyI32 = runtime.SquaresRuntimeFamilyI32;
const squares_family_version = model.squares_family_version;
const squaresFamilyTarget = model.squaresFamilyTarget;
const squaresFamilyEntryName = model.squaresFamilyEntryName;
const squaresFamilyFingerprint = model.squaresFamilyFingerprint;
const squaresShapeProfileDimensions = model.squaresShapeProfileDimensions;
const randomFoldDerivedLaunch = base.randomFoldDerivedLaunch;

pub fn createSquaresFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: Squares,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try squaresFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try squaresFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try squaresFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = squaresShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "squares",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try SquaresRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .i32 => try SquaresRuntimeFamilyI32.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = squares_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try randomFoldDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 3 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

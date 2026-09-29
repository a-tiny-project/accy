const std = @import("std");

const accy = @import("../../../../../root.zig");
const artifact_product = @import("../../../../../artifact/model/root.zig");
const library = @import("../../../root.zig");
const body = @import("body.zig");
const family = @import("../root.zig");

const entry = library.entry;
const kernel = accy.kernel;
const Histogram = family.Histogram;

pub fn createHistogramFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: Histogram,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (!family.histogramInstanceValid(instance)) return error.InvalidKernelLibraryEntry;
    const target = try family.histogramFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try family.histogramFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try family.histogramFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = family.histogramShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "histogram",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try body.HistogramRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = family.histogram_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try histogramDerivedLaunch(instance),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 4 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

fn histogramDerivedLaunch(instance: Histogram) !artifact_product.KernelCallLaunch {
    if (instance.threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 1, .divisor = instance.threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ instance.threads, 1, 1 },
    } };
}

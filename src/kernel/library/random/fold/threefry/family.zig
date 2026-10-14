const gpu_abi = @import("gpu_abi");
const random = @import("../../root.zig");

const base = random.base;
const block = random.block;
const runtime = @import("runtime.zig");
const types = @import("types.zig");

const std = base.std;
const artifact_product = base.artifact_product;
const shape = base.shape;
const entry = base.entry;
const kernel = base.kernel;
const tuning = base.tuning;
const runtimeExtentArgument = base.runtimeExtentArgument;

const threefryBlock = block.threefryBlock;
const uniformFromBits = block.uniformFromBits;
const randomRuntimeExtentBounds = base.randomRuntimeExtentBounds;
const randomShapeFamily = base.randomShapeFamily;
const randomFoldDerivedLaunch = base.randomFoldDerivedLaunch;

pub const threefry_fold_family_version = types.threefry_fold_family_version;
pub const ThreefryFold = types.ThreefryFold;
pub const ThreefryFoldRuntimeFamilyF32 = runtime.ThreefryFoldRuntimeFamilyF32;
pub const ThreefryFoldRuntimeFamilyI32 = runtime.ThreefryFoldRuntimeFamilyI32;

pub fn threefryFoldUniformReference(rounds: u32, output_index: u32, samples: u32, key: [2]u32) f32 {
    var accumulator: f32 = 0.0;
    for (0..samples) |sample| {
        const words = threefryBlock(rounds, .{ output_index, @intCast(sample) }, key);
        for (words) |word| accumulator += uniformFromBits(word);
    }
    return accumulator;
}

pub fn threefryFoldBitsReference(rounds: u32, output_index: u32, samples: u32, key: [2]u32) u32 {
    var accumulator: u32 = 0;
    for (0..samples) |sample| {
        const words = threefryBlock(rounds, .{ output_index, @intCast(sample) }, key);
        for (words) |word| accumulator ^= word;
    }
    return accumulator;
}

pub fn threefryFoldFamilyTarget(allocator: std.mem.Allocator, instance: ThreefryFold) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.threefry_fold_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn threefryFoldFamilyEntryName(allocator: std.mem.Allocator, instance: ThreefryFold) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_threefry_fold_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}
pub fn threefryFoldRuntimeArguments(instance: ThreefryFold) ![4]gpu_abi.ScalarArgument {
    if (instance.samples == 0) return error.ExtentOverflowsIndexRange;
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.count) },
        .{ .u32 = instance.samples },
        .{ .u32 = instance.seedLo() },
        .{ .u32 = instance.seedHi() },
    };
}
pub fn threefryFoldShapeProfileDimensions(
    instance: ThreefryFold,
) [2]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.count_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = randomRuntimeExtentBounds(),
        },
        .{ .name = "k", .runtime_scalar_argument_index = 1, .bounds = randomRuntimeExtentBounds() },
    };
}
pub fn threefryFoldTuningExtents(instance: ThreefryFold) [2]u64 {
    return .{ instance.count, instance.samples };
}

pub fn threefryFoldTuningOperation(instance: ThreefryFold) entry.Operation {
    return .{ .random = .{ .threefry_fold = instance.rounds } };
}

pub fn threefryFoldFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: ThreefryFold,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try threefryFoldFamilyFingerprint(backing_allocator, instance);
    const extents = threefryFoldTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(threefryFoldTuningOperation(instance)),
        instance.dtype,
        threefry_fold_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn threefryFoldFamilyFingerprint(
    backing_allocator: std.mem.Allocator,
    instance: ThreefryFold,
) !u64 {
    var family = try randomShapeFamily(backing_allocator, "threefry_fold", instance.count_axis);
    defer family.deinit();
    return shape.fingerprint(family);
}
pub fn createThreefryFoldFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: ThreefryFold,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try threefryFoldFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try threefryFoldFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse
        try threefryFoldFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = threefryFoldShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "threefry_fold",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try ThreefryFoldRuntimeFamilyF32.buildNamed(
            allocator,
            options.limits,
            entry_name,
            instance,
        ),
        .i32 => try ThreefryFoldRuntimeFamilyI32.buildNamed(
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
        .version = threefry_fold_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try randomFoldDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0)
            4
        else
            options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

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

const philoxBlock = block.philoxBlock;
const uniformFromBits = block.uniformFromBits;
const randomRuntimeExtentBounds = base.randomRuntimeExtentBounds;
const randomShapeFamily = base.randomShapeFamily;
const randomFoldDerivedLaunch = base.randomFoldDerivedLaunch;

pub const philox_fold_family_version = types.philox_fold_family_version;
pub const PhiloxFold = types.PhiloxFold;
pub const PhiloxFoldRuntimeFamilyF32 = runtime.PhiloxFoldRuntimeFamilyF32;
pub const PhiloxFoldRuntimeFamilyI32 = runtime.PhiloxFoldRuntimeFamilyI32;

pub fn philoxFoldUniformReference(rounds: u32, output_index: u32, samples: u32, key: [2]u32) f32 {
    var accumulator: f32 = 0.0;
    for (0..samples) |sample| {
        const words = philoxBlock(rounds, .{ output_index, @intCast(sample), 0, 0 }, key);
        for (words) |word| accumulator += uniformFromBits(word);
    }
    return accumulator;
}

pub fn philoxFoldBitsReference(rounds: u32, output_index: u32, samples: u32, key: [2]u32) u32 {
    var accumulator: u32 = 0;
    for (0..samples) |sample| {
        const words = philoxBlock(rounds, .{ output_index, @intCast(sample), 0, 0 }, key);
        for (words) |word| accumulator ^= word;
    }
    return accumulator;
}

pub fn philoxFoldFamilyTarget(allocator: std.mem.Allocator, instance: PhiloxFold) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.philox_fold_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn philoxFoldFamilyEntryName(allocator: std.mem.Allocator, instance: PhiloxFold) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_philox_fold_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}
pub fn philoxFoldRuntimeArguments(instance: PhiloxFold) ![4]gpu_abi.ScalarArgument {
    if (instance.samples == 0) return error.ExtentOverflowsIndexRange;
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.count) },
        .{ .u32 = instance.samples },
        .{ .u32 = instance.seedLo() },
        .{ .u32 = instance.seedHi() },
    };
}
pub fn philoxFoldShapeProfileDimensions(instance: PhiloxFold) [2]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{ .name = instance.count_axis, .runtime_scalar_argument_index = 0, .bounds = randomRuntimeExtentBounds() },
        .{ .name = "k", .runtime_scalar_argument_index = 1, .bounds = randomRuntimeExtentBounds() },
    };
}
pub fn philoxFoldTuningExtents(instance: PhiloxFold) [2]u64 {
    return .{ instance.count, instance.samples };
}

pub fn philoxFoldTuningOperation(instance: PhiloxFold) entry.Operation {
    return .{ .random = .{ .philox_fold = instance.rounds } };
}

pub fn philoxFoldFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: PhiloxFold,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try philoxFoldFamilyFingerprint(backing_allocator, instance);
    const extents = philoxFoldTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(philoxFoldTuningOperation(instance)),
        instance.dtype,
        philox_fold_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn philoxFoldFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: PhiloxFold) !u64 {
    var family = try randomShapeFamily(backing_allocator, "philox_fold", instance.count_axis);
    defer family.deinit();
    return shape.fingerprint(family);
}
pub fn createPhiloxFoldFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: PhiloxFold,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try philoxFoldFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try philoxFoldFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try philoxFoldFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = philoxFoldShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "philox_fold",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try PhiloxFoldRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .i32 => try PhiloxFoldRuntimeFamilyI32.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = philox_fold_family_version,
        .format = options.format,
        .kernel_plan = options.kernel_plan,
        .element_count_argument = options.element_count_argument,
        .shape_family_fingerprint = family_fingerprint,
        .shape_profile = shape_profile,
        .launch = options.launch orelse try randomFoldDerivedLaunch(instance.threads),
        .runtime_scalar_argument_count = if (options.runtime_scalar_argument_count == 0) 4 else options.runtime_scalar_argument_count,
        .static_arguments = options.static_arguments,
    });
}

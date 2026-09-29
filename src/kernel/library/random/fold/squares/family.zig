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

const squaresBlock = block.squaresBlock;
const uniformFromBits = block.uniformFromBits;
const randomRuntimeExtentBounds = base.randomRuntimeExtentBounds;
const randomShapeFamily = base.randomShapeFamily;
const randomFoldDerivedLaunch = base.randomFoldDerivedLaunch;

pub const SquaresFold = types.SquaresFold;
pub const squares_fold_family_version = types.squares_fold_family_version;
pub const SquaresFoldRuntimeFamilyF32 = runtime.SquaresFoldRuntimeFamilyF32;
pub const SquaresFoldRuntimeFamilyI32 = runtime.SquaresFoldRuntimeFamilyI32;

pub fn squaresFoldUniformReference(output_index: u32, samples: u32, key: u64) f32 {
    var accumulator: f32 = 0.0;
    for (0..samples) |sample| {
        const counter = @as(u64, output_index) | (@as(u64, @intCast(sample)) << 32);
        accumulator += uniformFromBits(squaresBlock(counter, key));
    }
    return accumulator;
}

pub fn squaresFoldBitsReference(output_index: u32, samples: u32, key: u64) u32 {
    var accumulator: u32 = 0;
    for (0..samples) |sample| {
        const counter = @as(u64, output_index) | (@as(u64, @intCast(sample)) << 32);
        accumulator ^= squaresBlock(counter, key);
    }
    return accumulator;
}

pub fn squaresFoldFamilyTarget(allocator: std.mem.Allocator, instance: SquaresFold) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.squares_fold_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn squaresFoldFamilyEntryName(allocator: std.mem.Allocator, instance: SquaresFold) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_squares_fold_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn squaresFoldRuntimeArguments(instance: SquaresFold) ![4]gpu_abi.ScalarArgument {
    if (instance.samples == 0) return error.ExtentOverflowsIndexRange;
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.count) },
        .{ .u32 = instance.samples },
        .{ .u32 = instance.keyLo() },
        .{ .u32 = instance.keyHi() },
    };
}

pub fn squaresFoldShapeProfileDimensions(instance: SquaresFold) [2]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{ .name = instance.count_axis, .runtime_scalar_argument_index = 0, .bounds = randomRuntimeExtentBounds() },
        .{ .name = "k", .runtime_scalar_argument_index = 1, .bounds = randomRuntimeExtentBounds() },
    };
}

pub fn squaresFoldTuningExtents(instance: SquaresFold) [2]u64 {
    return .{ instance.count, instance.samples };
}

pub fn squaresFoldTuningOperation(instance: SquaresFold) entry.Operation {
    _ = instance;
    return .{ .random = .squares_fold };
}

pub fn squaresFoldFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: SquaresFold,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try squaresFoldFamilyFingerprint(backing_allocator, instance);
    const extents = squaresFoldTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(squaresFoldTuningOperation(instance)),
        instance.dtype,
        squares_fold_family_version,
        extents[0..],
    ) orelse unreachable;
}

pub fn squaresFoldFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: SquaresFold) !u64 {
    var family = try randomShapeFamily(backing_allocator, "squares_fold", instance.count_axis);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn createSquaresFoldFamilyArtifact(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    instance: SquaresFold,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    const target = try squaresFoldFamilyTarget(allocator, instance);
    defer allocator.free(target);
    const entry_name = try squaresFoldFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);
    const family_fingerprint = options.shape_family_fingerprint orelse try squaresFoldFamilyFingerprint(allocator, instance);
    const shape_profile_dimensions = squaresFoldShapeProfileDimensions(instance);
    const shape_profile = options.shape_profile orelse artifact_product.KernelCallShapeProfile{
        .name = "squares_fold",
        .fingerprint = family_fingerprint,
        .dimensions = shape_profile_dimensions[0..],
    };

    var graph = switch (instance.dtype) {
        .f32 => try SquaresFoldRuntimeFamilyF32.buildNamed(allocator, options.limits, entry_name, instance),
        .i32 => try SquaresFoldRuntimeFamilyI32.buildNamed(allocator, options.limits, entry_name, instance),
        else => return error.UnsupportedDType,
    };
    defer graph.deinit();
    return kernel.createKernelCallArtifact(allocator, handle, &graph, .{
        .target = target,
        .version = squares_fold_family_version,
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

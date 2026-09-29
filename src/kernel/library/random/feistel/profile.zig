const gpu_abi = @import("gpu_abi");
const random = @import("../root.zig");
const types = @import("types.zig");

const base = random.base;

const std = base.std;
const artifact_product = base.artifact_product;
const shape = base.shape;
const runtimeExtentArgument = base.runtimeExtentArgument;
const randomRuntimeExtentBounds = base.randomRuntimeExtentBounds;
const randomShapeFamily = base.randomShapeFamily;

const Feistel = types.Feistel;

pub fn feistelRuntimeArguments(instance: Feistel) ![3]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.count) },
        .{ .u32 = instance.seedLo() },
        .{ .u32 = instance.seedHi() },
    };
}

pub fn feistelShapeProfileDimensions(instance: Feistel) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{ .name = instance.count_axis, .runtime_scalar_argument_index = 0, .bounds = randomRuntimeExtentBounds() },
    };
}

pub fn feistelFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: Feistel) !u64 {
    var family = try feistelShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn feistelShapeFamily(backing_allocator: std.mem.Allocator, instance: Feistel) !shape.Family {
    return randomShapeFamily(backing_allocator, "feistel", instance.count_axis);
}

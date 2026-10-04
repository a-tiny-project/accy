const gpu_abi = @import("gpu_abi");
const random = @import("../root.zig");
const types = @import("types.zig");

const base = random.base;
const block = random.block;

const std = base.std;
const artifact_product = base.artifact_product;
const shape = base.shape;
const entry = base.entry;
const runtimeExtentArgument = base.runtimeExtentArgument;
const randomRuntimeExtentBounds = base.randomRuntimeExtentBounds;
const randomShapeFamily = base.randomShapeFamily;
const randomDTypeSupported = block.randomDTypeSupported;

const Squares = types.Squares;

pub fn squaresRuntimeArguments(instance: Squares) ![3]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.count) },
        .{ .u32 = instance.keyLo() },
        .{ .u32 = instance.keyHi() },
    };
}

pub fn squaresShapeProfileDimensions(
    instance: Squares,
) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{
        .{
            .name = instance.count_axis,
            .runtime_scalar_argument_index = 0,
            .bounds = randomRuntimeExtentBounds(),
        },
    };
}

pub fn squaresFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: Squares) !u64 {
    var family = try squaresShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn squaresShapeFamily(backing_allocator: std.mem.Allocator, instance: Squares) !shape.Family {
    return randomShapeFamily(backing_allocator, "squares", instance.count_axis);
}

pub fn squaresFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: Squares,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.count_axis, instance.count);

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .random = .squares },
        .inputs = &.{},
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            "e",
            instance.generators(),
            instance.threads,
        ),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try squaresShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn squaresInstanceFromSpecialization(specialization: entry.Specialization) ?Squares {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const operation = specialization.operation orelse return null;
    switch (operation) {
        .random => |random_operation| switch (random_operation) {
            .squares => {},
            else => return null,
        },
        else => return null,
    }
    const dtype = specialization.dtype orelse return null;
    if (!randomDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 0 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const output = specialization.outputs[0];
    if (output.axes.len != 1) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    return .{
        .count = output.axes[0].extent,
        .dtype = dtype,
        .threads = launch.threadgroup[0],
        .count_axis = output.axes[0].name,
    };
}

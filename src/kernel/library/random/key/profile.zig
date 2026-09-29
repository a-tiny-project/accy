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

const PhiloxKeySplit = types.PhiloxKeySplit;
const PhiloxKeyUniform = types.PhiloxKeyUniform;
const PhiloxKeyCounterUniform = types.PhiloxKeyCounterUniform;

pub fn philoxKeySplitRuntimeArguments(instance: PhiloxKeySplit) ![1]gpu_abi.ScalarArgument {
    return .{.{ .u32 = try runtimeExtentArgument(instance.count) }};
}

pub fn philoxKeyUniformRuntimeArguments(instance: PhiloxKeyUniform) ![1]gpu_abi.ScalarArgument {
    return .{.{ .u32 = try runtimeExtentArgument(instance.count) }};
}

pub fn philoxKeyCounterUniformRuntimeArguments(instance: PhiloxKeyCounterUniform) ![1]gpu_abi.ScalarArgument {
    return .{.{ .u32 = try runtimeExtentArgument(instance.count) }};
}

pub fn philoxKeySplitShapeProfileDimensions(instance: PhiloxKeySplit) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{.{ .name = instance.count_axis, .runtime_scalar_argument_index = 0, .bounds = randomRuntimeExtentBounds() }};
}

pub fn philoxKeyUniformShapeProfileDimensions(instance: PhiloxKeyUniform) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{.{ .name = instance.count_axis, .runtime_scalar_argument_index = 0, .bounds = randomRuntimeExtentBounds() }};
}

pub fn philoxKeyCounterUniformShapeProfileDimensions(instance: PhiloxKeyCounterUniform) [1]artifact_product.KernelCallShapeProfileDimension {
    return .{.{ .name = instance.count_axis, .runtime_scalar_argument_index = 0, .bounds = randomRuntimeExtentBounds() }};
}

pub fn philoxKeySplitFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: PhiloxKeySplit) !u64 {
    var family = try philoxKeySplitShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn philoxKeyUniformFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: PhiloxKeyUniform) !u64 {
    var family = try philoxKeyUniformShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn philoxKeyCounterUniformFamilyFingerprint(backing_allocator: std.mem.Allocator, instance: PhiloxKeyCounterUniform) !u64 {
    var family = try philoxKeyCounterUniformShapeFamily(backing_allocator, instance);
    defer family.deinit();
    return shape.fingerprint(family);
}

pub fn philoxKeySplitShapeFamily(backing_allocator: std.mem.Allocator, instance: PhiloxKeySplit) !shape.Family {
    return randomShapeFamily(backing_allocator, "philox_key_split", instance.count_axis);
}

pub fn philoxKeyUniformShapeFamily(backing_allocator: std.mem.Allocator, instance: PhiloxKeyUniform) !shape.Family {
    return randomShapeFamily(backing_allocator, "philox_key_uniform", instance.count_axis);
}

pub fn philoxKeyCounterUniformShapeFamily(backing_allocator: std.mem.Allocator, instance: PhiloxKeyCounterUniform) !shape.Family {
    return randomShapeFamily(backing_allocator, "philox_key_counter_uniform", instance.count_axis);
}

pub fn philoxKeySplitFamilySpecialization(backing_allocator: std.mem.Allocator, instance: PhiloxKeySplit) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 1);
    inputs[0] = entry.runtimeShapeScalar();
    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.count_axis, instance.count);

    owned.value = .{
        .dtype = .key,
        .operation = .{ .random = .{ .philox_key_split = instance.rounds } },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, "e", instance.generators(), instance.threads),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try philoxKeySplitShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn philoxKeyUniformFamilySpecialization(backing_allocator: std.mem.Allocator, instance: PhiloxKeyUniform) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 1);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.count_axis, instance.count);
    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.count_axis, instance.count);

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .random = .{ .philox_key_uniform = instance.rounds } },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, "e", instance.generators(), instance.threads),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try philoxKeyUniformShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn philoxKeyCounterUniformFamilySpecialization(backing_allocator: std.mem.Allocator, instance: PhiloxKeyCounterUniform) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
    inputs[0] = entry.runtimeShapeScalar();
    inputs[1] = entry.runtimeShapeScalar();
    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.count_axis, instance.count);

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .random = .{ .philox_key_counter_uniform = instance.rounds } },
        .inputs = inputs,
        .outputs = outputs,
        .schedule = try entry.runtimeThreadBlocks1D(lifetime_allocator, "e", instance.generators(), instance.threads),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try philoxKeyCounterUniformShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn philoxKeySplitInstanceFromSpecialization(specialization: entry.Specialization) ?PhiloxKeySplit {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const operation = specialization.operation orelse return null;
    const rounds = switch (operation) {
        .random => |random_operation| switch (random_operation) {
            .philox_key_split => |rounds| rounds,
            else => return null,
        },
        else => return null,
    };
    const dtype = specialization.dtype orelse return null;
    if (dtype != .key) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.inputs[0].axes.len != 0) return null;
    if (specialization.reductions.len != 0) return null;
    const output = specialization.outputs[0];
    if (output.axes.len != 1) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    return .{
        .count = output.axes[0].extent,
        .rounds = rounds,
        .threads = launch.threadgroup[0],
        .count_axis = output.axes[0].name,
    };
}

pub fn philoxKeyCounterUniformInstanceFromSpecialization(specialization: entry.Specialization) ?PhiloxKeyCounterUniform {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const operation = specialization.operation orelse return null;
    const rounds = switch (operation) {
        .random => |random_operation| switch (random_operation) {
            .philox_key_counter_uniform => |rounds| rounds,
            else => return null,
        },
        else => return null,
    };
    const dtype = specialization.dtype orelse return null;
    if (!randomDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    if (specialization.inputs[0].axes.len != 0 or specialization.inputs[1].axes.len != 0) return null;
    const output = specialization.outputs[0];
    if (output.axes.len != 1) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    return .{
        .count = output.axes[0].extent,
        .rounds = rounds,
        .dtype = dtype,
        .threads = launch.threadgroup[0],
        .count_axis = output.axes[0].name,
    };
}

pub fn philoxKeyUniformInstanceFromSpecialization(specialization: entry.Specialization) ?PhiloxKeyUniform {
    if (!specialization.scheduleMatchesLaunch()) return null;
    const operation = specialization.operation orelse return null;
    const rounds = switch (operation) {
        .random => |random_operation| switch (random_operation) {
            .philox_key_uniform => |rounds| rounds,
            else => return null,
        },
        else => return null,
    };
    const dtype = specialization.dtype orelse return null;
    if (!randomDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    const input = specialization.inputs[0];
    const output = specialization.outputs[0];
    if (input.axes.len != 1 or output.axes.len != 1) return null;
    if (input.axes[0].extent != output.axes[0].extent) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    return .{
        .count = output.axes[0].extent,
        .rounds = rounds,
        .dtype = dtype,
        .threads = launch.threadgroup[0],
        .count_axis = output.axes[0].name,
    };
}

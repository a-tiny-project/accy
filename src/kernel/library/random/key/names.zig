const random = @import("../root.zig");
const types = @import("types.zig");

const std = random.base.std;
const PhiloxKeySplit = types.PhiloxKeySplit;
const PhiloxKeyUniform = types.PhiloxKeyUniform;
const PhiloxKeyCounterUniform = types.PhiloxKeyCounterUniform;

pub fn philoxKeySplitFamilyTarget(allocator: std.mem.Allocator, instance: PhiloxKeySplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.philox_key_split_family_{d}r_{d}_key",
        .{ instance.rounds, instance.threads },
    );
}

pub fn philoxKeySplitFamilyEntryName(allocator: std.mem.Allocator, instance: PhiloxKeySplit) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_philox_key_split_family_{d}r_{d}_key",
        .{ instance.rounds, instance.threads },
    );
}

pub fn philoxKeyUniformFamilyTarget(
    allocator: std.mem.Allocator,
    instance: PhiloxKeyUniform,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.philox_key_uniform_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn philoxKeyUniformFamilyEntryName(
    allocator: std.mem.Allocator,
    instance: PhiloxKeyUniform,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_philox_key_uniform_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn philoxKeyCounterUniformFamilyTarget(
    allocator: std.mem.Allocator,
    instance: PhiloxKeyCounterUniform,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.philox_key_counter_uniform_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn philoxKeyCounterUniformFamilyEntryName(
    allocator: std.mem.Allocator,
    instance: PhiloxKeyCounterUniform,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_philox_key_counter_uniform_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}

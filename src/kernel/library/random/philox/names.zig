const random = @import("../root.zig");
const types = @import("types.zig");

const std = random.base.std;
const Philox = types.Philox;

pub fn philoxInstanceTarget(allocator: std.mem.Allocator, instance: Philox) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.philox{d}_{d}r_{d}_{s}",
        .{ instance.count, instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn philoxInstanceEntryName(allocator: std.mem.Allocator, instance: Philox) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_philox{d}_{d}r_{d}_{s}",
        .{ instance.count, instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn philoxFamilyTarget(allocator: std.mem.Allocator, instance: Philox) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.philox_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn philoxFamilyEntryName(allocator: std.mem.Allocator, instance: Philox) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_philox_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}

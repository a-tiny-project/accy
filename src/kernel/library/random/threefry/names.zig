const random = @import("../root.zig");
const types = @import("types.zig");

const std = random.base.std;
const Threefry = types.Threefry;

pub fn threefryInstanceTarget(allocator: std.mem.Allocator, instance: Threefry) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.threefry{d}_{d}r_{d}_{s}",
        .{ instance.count, instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn threefryInstanceEntryName(allocator: std.mem.Allocator, instance: Threefry) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_threefry{d}_{d}r_{d}_{s}",
        .{ instance.count, instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn threefryFamilyTarget(allocator: std.mem.Allocator, instance: Threefry) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.threefry_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn threefryFamilyEntryName(allocator: std.mem.Allocator, instance: Threefry) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_threefry_family_{d}r_{d}_{s}",
        .{ instance.rounds, instance.threads, instance.dtype.name() },
    );
}

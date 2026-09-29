const random = @import("../root.zig");
const types = @import("types.zig");

const std = random.base.std;
const Feistel = types.Feistel;

pub fn feistelFamilyTarget(allocator: std.mem.Allocator, instance: Feistel) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.feistel_family_{d}b_{d}r_{d}_{s}",
        .{ instance.domainBits().?, instance.rounds, instance.threads, instance.dtype.name() },
    );
}

pub fn feistelFamilyEntryName(allocator: std.mem.Allocator, instance: Feistel) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_feistel_family_{d}b_{d}r_{d}_{s}",
        .{ instance.domainBits().?, instance.rounds, instance.threads, instance.dtype.name() },
    );
}

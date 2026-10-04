const random = @import("../root.zig");
const types = @import("types.zig");

const std = random.base.std;
const Squares = types.Squares;

pub fn squaresFamilyTarget(allocator: std.mem.Allocator, instance: Squares) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy.kernel.random.squares_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

pub fn squaresFamilyEntryName(allocator: std.mem.Allocator, instance: Squares) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "accy_kernel_random_squares_family_{d}_{s}",
        .{ instance.threads, instance.dtype.name() },
    );
}

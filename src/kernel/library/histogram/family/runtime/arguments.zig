const gpu_abi = @import("gpu_abi");
const library = @import("../../../root.zig");
const family = @import("../root.zig");

const extent = library.extent;
const Histogram = family.Histogram;

pub fn histogramRuntimeArguments(instance: Histogram) ![4]gpu_abi.ScalarArgument {
    return .{
        .{ .u32 = try runtimeExtentArgument(instance.bins) },
        .{ .u32 = try runtimeExtentArgument(instance.count) },
        .{ .f32 = instance.lo },
        .{ .f32 = instance.width },
    };
}

fn runtimeExtentArgument(value: u64) !u32 {
    if (value == 0 or value > extent.runtime_extent_max) return error.InvalidKernelLibraryEntry;
    return @intCast(value);
}

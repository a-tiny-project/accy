const gpu_abi = @import("gpu_abi");
pub const std = @import("std");

pub const artifact_product = @import("../../../artifact/model/root.zig");
pub const shape = @import("../../../choir/shape/root.zig");
pub const library = @import("../root.zig");
pub const kernel = @import("../../root.zig");

pub const entry = library.entry;
pub const extent_mod = library.extent;
pub const geometry_mod = library.geometry;
pub const tuning = library.tuning;

pub const DType = gpu_abi.DType;
pub const indexExtent = extent_mod.indexExtent;
pub const runtimeExtentArgument = extent_mod.runtimeExtentArgument;
pub const random_thread_caps = geometry_mod.ThreadCaps1D{};

pub fn randomRuntimeExtentBounds() shape.Bounds {
    return .{ .min = 1, .max = extent_mod.runtime_extent_max };
}

pub fn randomDerivedLaunch(threads: u32, lanes: u64) !artifact_product.KernelCallLaunch {
    if (threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    const divisor = std.math.cast(u32, @as(u64, threads) * lanes) orelse
        return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = divisor } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ threads, 1, 1 },
    } };
}

pub fn randomFoldDerivedLaunch(threads: u32) !artifact_product.KernelCallLaunch {
    if (threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    return .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = threads } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ threads, 1, 1 },
    } };
}

pub fn randomShapeFamily(
    backing_allocator: std.mem.Allocator,
    name: []const u8,
    count_axis: []const u8,
) !shape.Family {
    var builder = try shape.Builder.init(backing_allocator, name);
    errdefer builder.deinit();

    const count = try builder.symbol(count_axis);
    const count_expr = try builder.symbolExpression(count);
    _ = try builder.tensor("out", &.{count_expr});
    try builder.assumeBounds(count_expr, randomRuntimeExtentBounds());

    return builder.finish();
}

pub fn ceilDivComptime(comptime numerator: u64, comptime denominator: u32) u32 {
    return @intCast(numerator / denominator + @as(u64, @intFromBool(numerator % denominator != 0)));
}

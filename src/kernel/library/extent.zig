const std = @import("std");

pub const runtime_extent_max: u64 = @as(u64, @intCast(std.math.maxInt(i32)));

pub fn indexExtent(extent: u64) !i64 {
    return std.math.cast(i64, extent) orelse error.ExtentOverflowsIndexRange;
}

pub fn indexProduct(lhs: u64, rhs: u64) !i64 {
    const product = std.math.mul(u64, lhs, rhs) catch return error.ExtentOverflowsIndexRange;
    return indexExtent(product);
}

pub fn runtimeExtentArgument(extent: u64) !u32 {
    if (extent == 0 or extent > runtime_extent_max) return error.ExtentOverflowsIndexRange;
    return @intCast(extent);
}

pub fn blockCountWithinLimit(extent: u64, threads: u32, max_blocks: u32) bool {
    if (threads == 0) return false;
    return extent <= @as(u64, threads) * max_blocks;
}

const testing = std.testing;

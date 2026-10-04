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

test "index extent accepts the full unsigned index range" {
    try testing.expectEqual(@as(i64, 0), try indexExtent(0));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try indexExtent(
        @as(u64, @intCast(std.math.maxInt(i64))),
    ));
    try testing.expectError(error.ExtentOverflowsIndexRange, indexExtent(
        @as(u64, @intCast(std.math.maxInt(i64))) + 1,
    ));
}

test "index product checks overflow before conversion" {
    try testing.expectEqual(@as(i64, 12), try indexProduct(3, 4));
    try testing.expectError(error.ExtentOverflowsIndexRange, indexProduct(std.math.maxInt(u64), 2));
}

test "runtime extent argument bounds to nonzero i32 range" {
    try testing.expectEqual(@as(u32, 1), try runtimeExtentArgument(1));
    try testing.expectEqual(
        @as(u32, @intCast(runtime_extent_max)),
        try runtimeExtentArgument(runtime_extent_max),
    );
    try testing.expectError(error.ExtentOverflowsIndexRange, runtimeExtentArgument(0));
    try testing.expectError(
        error.ExtentOverflowsIndexRange,
        runtimeExtentArgument(runtime_extent_max + 1),
    );
}

test "block count limit rejects oversized extents without overflowing" {
    try testing.expect(blockCountWithinLimit(1, 32, 4));
    try testing.expect(blockCountWithinLimit(128, 32, 4));
    try testing.expect(!blockCountWithinLimit(129, 32, 4));
    try testing.expect(!blockCountWithinLimit(std.math.maxInt(u64), 32, 1024));
    try testing.expect(!blockCountWithinLimit(1, 0, 1024));
}

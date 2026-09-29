const std = @import("std");
const window = @import("window.zig");
const presentation = @import("presentation.zig");

pub const Frame = struct {
    width: u32,
    height: u32,
    byte_count: usize,
    regions: [window.max_present_regions]window.PresentRegion = undefined,
    count: usize = 0,
    empty_fallback: bool = false,

    pub fn init(source: []const u8, width: u32, height: u32, regions: []const window.PresentRegion) window.PresentError!Frame {
        if (regions.len > window.max_present_regions) return error.TooManyRegions;
        const bytes = presentation.rgba8ByteCount(width, height) orelse return error.UnsupportedFormat;
        if (source.len < bytes) return error.UnsupportedFormat;
        var result = Frame{ .width = width, .height = height, .byte_count = bytes };
        for (regions) |region| {
            const clipped = region.clamped(width, height);
            if (clipped.width == 0 or clipped.height == 0) continue;
            result.regions[result.count] = clipped;
            result.count += 1;
        }
        if (result.count == 0) {
            result.empty_fallback = regions.len > 0;
            result.cover();
        }
        return result;
    }

    pub fn cover(self: *Frame) void {
        self.regions[0] = window.PresentRegion.full(self.width, self.height);
        self.count = 1;
    }

    pub fn slice(self: *const Frame) []const window.PresentRegion {
        return self.regions[0..self.count];
    }

    pub fn bounds(self: *const Frame) window.PresentRegion {
        std.debug.assert(self.count > 0);
        var left = self.width;
        var top = self.height;
        var right: u32 = 0;
        var bottom: u32 = 0;
        for (self.slice()) |region| {
            left = @min(left, region.x);
            top = @min(top, region.y);
            right = @max(right, region.x + region.width);
            bottom = @max(bottom, region.y + region.height);
        }
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }
};

pub const Ids = struct {
    next: u64 = 1,

    pub fn reserve(self: *const Ids) error{SubmissionIdsExhausted}!u64 {
        if (self.next == 0) return error.SubmissionIdsExhausted;
        return self.next;
    }

    pub fn accept(self: *Ids, id: u64) void {
        std.debug.assert(id == self.next);
        std.debug.assert(id > 0);
        self.next +%= 1;
    }
};

test "frame region validation clamps and uses full fallback at the declared bound" {
    const source: [64]u8 = @splat(0);
    const full = try Frame.init(&source, 4, 4, &.{});
    try std.testing.expectEqual(window.PresentRegion.full(4, 4), full.bounds());
    try std.testing.expect(!full.empty_fallback);
    const empty = try Frame.init(&source, 4, 4, &.{.{ .x = 5, .width = 2, .height = 2 }});
    try std.testing.expect(empty.empty_fallback);
    try std.testing.expectEqual(full.bounds(), empty.bounds());
    const regions: [window.max_present_regions + 1]window.PresentRegion = @splat(.{ .x = 3, .y = 2, .width = 9, .height = 9 });
    const clipped = try Frame.init(&source, 4, 4, regions[0..window.max_present_regions]);
    try std.testing.expectEqual(window.max_present_regions, clipped.count);
    try std.testing.expectEqual(window.PresentRegion{ .x = 3, .y = 2, .width = 1, .height = 2 }, clipped.bounds());
    try std.testing.expectError(error.TooManyRegions, Frame.init(&source, 4, 4, &regions));
    try std.testing.expectError(error.UnsupportedFormat, Frame.init(&source, 0, 4, &.{}));
    try std.testing.expectError(error.UnsupportedFormat, Frame.init(source[0..63], 4, 4, &.{}));
}

test "acceptance ids reserve without consuming and exhaust without wrapping to zero" {
    var ids = Ids{};
    try std.testing.expectEqual(@as(u64, 1), try ids.reserve());
    try std.testing.expectEqual(@as(u64, 1), try ids.reserve());
    ids.accept(1);
    try std.testing.expectEqual(@as(u64, 2), try ids.reserve());
    ids.next = std.math.maxInt(u64);
    ids.accept(try ids.reserve());
    try std.testing.expectError(error.SubmissionIdsExhausted, ids.reserve());
}

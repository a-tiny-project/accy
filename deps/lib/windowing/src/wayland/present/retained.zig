const std = @import("std");
const windowing = @import("../../root.zig");

const damage = @import("damage.zig");

const Region = windowing.PresentRegion;

/// A copy of the pixels the caller last handed in, held in storage the value is
/// given from outside itself. The accumulator beside the copy records where the
/// copy differs from the logical frame. A present the compositor takes at once
/// reads the caller's own pixels, so the copy goes untouched and stays stale,
/// at no cost. A present that waits copies the stale rows into this frame,
/// after which the copy holds the logical frame and can feed any buffer's
/// damage.
pub const Frame = struct {
    bytes: []u8 = &.{},
    dirty: damage.Region = .{},
    width: u32 = 0,
    height: u32 = 0,
    byte_count: usize = 0,

    /// Declares the extent the copy is held at, so a change of window size
    /// reaches the copy before anything is written into it. An extent that
    /// differs from the one in force drops the copy's contents, covers the
    /// accumulator with the whole new extent, and answers true. By contrast,
    /// the extent already in force leaves the value as it was and answers
    /// false. The width and the height each have to be above zero.
    pub fn resize(self: *Frame, width: u32, height: u32) bool {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        if (self.width == width and self.height == height) return false;
        self.width = width;
        self.height = height;
        self.byte_count = 0;
        self.dirty.cover(width, height);
        return true;
    }

    /// Adds the region to the accumulator, marking the copy stale there so a
    /// later refresh knows which rows to copy. The call answers `.collapsed`
    /// when the accumulator ran out of room and fell back to one covering
    /// rectangle. An extent has to be in force before the call. The accumulator
    /// holds at least one rectangle when the call returns.
    pub fn invalidate(self: *Frame, region: Region) damage.Addition {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.height > 0);
        const addition = self.dirty.add(region);
        std.debug.assert(!self.dirty.isEmpty());
        return addition;
    }

    /// Copies the rows of every listed rectangle out of `source` into the copy,
    /// at the same offsets in both, so a present the compositor made wait takes
    /// a copy of the pixels it will send once the compositor is ready. The call
    /// empties the accumulator and records how many bytes the copy holds,
    /// leaving the copy equal to the logical frame. `source` holds the whole
    /// frame at the extent in force and fits in the storage the copy was given.
    pub fn refresh(self: *Frame, source: []const u8) void {
        std.debug.assert(source.len <= self.bytes.len);
        std.debug.assert(source.len == frameByteCount(self.width, self.height));
        const destination = self.bytes[0..source.len];
        const stride = @as(usize, self.width) * 4;
        for (self.dirty.slice()) |region| {
            const row_byte_len = @as(usize, region.width) * 4;
            var row: u32 = 0;
            while (row < region.height) : (row += 1) {
                const offset = @as(usize, region.y + row) * stride + @as(usize, region.x) * 4;
                @memcpy(
                    destination[offset..][0..row_byte_len],
                    source[offset..][0..row_byte_len],
                );
            }
        }
        self.dirty.clear();
        self.byte_count = source.len;
        std.debug.assert(self.isCurrent());
    }

    pub fn isCurrent(self: *const Frame) bool {
        return self.dirty.isEmpty();
    }

    pub fn contents(self: *const Frame) []const u8 {
        std.debug.assert(self.byte_count <= self.bytes.len);
        return self.bytes[0..self.byte_count];
    }
};

fn frameByteCount(width: u32, height: u32) usize {
    return @as(usize, width) * @as(usize, height) * 4;
}

const test_width: u32 = 8;
const test_height: u32 = 6;
const test_bytes: usize = test_width * test_height * 4;

fn paint(frame: []u8, seed: u8) void {
    for (frame, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% seed);
}

test "a resized retained frame reports the reset and stales every byte" {
    var storage: [test_bytes]u8 = @splat(0);
    var frame = Frame{ .bytes = storage[0..] };
    try std.testing.expect(frame.resize(test_width, test_height));
    try std.testing.expect(!frame.resize(test_width, test_height));
    try std.testing.expect(!frame.isCurrent());
    try std.testing.expectEqualSlices(
        Region,
        &.{.{ .x = 0, .y = 0, .width = test_width, .height = test_height }},
        frame.dirty.slice(),
    );
    try std.testing.expectEqual(@as(usize, 0), frame.contents().len);

    var source: [test_bytes]u8 = undefined;
    paint(&source, 3);
    frame.refresh(&source);
    try std.testing.expect(frame.isCurrent());
    try std.testing.expectEqualSlices(u8, &source, frame.contents());
}

test "a refresh copies the stale rows and no others" {
    var storage: [test_bytes]u8 = @splat(0);
    var frame = Frame{ .bytes = storage[0..] };
    _ = frame.resize(test_width, test_height);
    var first: [test_bytes]u8 = undefined;
    paint(&first, 1);
    frame.refresh(&first);

    var second: [test_bytes]u8 = undefined;
    paint(&second, 200);
    const stale = Region{ .x = 2, .y = 1, .width = 3, .height = 2 };
    try std.testing.expectEqual(damage.Addition.exact, frame.invalidate(stale));
    frame.refresh(&second);

    var expected = first;
    for (1..3) |row| {
        const offset = (row * test_width + 2) * 4;
        @memcpy(expected[offset..][0 .. 3 * 4], second[offset..][0 .. 3 * 4]);
    }
    try std.testing.expectEqualSlices(u8, &expected, frame.contents());
}

test "a refresh copies the rows of every listed rectangle and no others" {
    var storage: [test_bytes]u8 = @splat(0);
    var frame = Frame{ .bytes = storage[0..] };
    _ = frame.resize(test_width, test_height);
    var first: [test_bytes]u8 = undefined;
    paint(&first, 1);
    frame.refresh(&first);

    var second: [test_bytes]u8 = undefined;
    paint(&second, 200);
    const stale = [_]Region{
        .{ .x = 0, .y = 0, .width = 2, .height = 1 },
        .{ .x = 5, .y = 3, .width = 3, .height = 3 },
    };
    for (stale) |region| {
        try std.testing.expectEqual(damage.Addition.exact, frame.invalidate(region));
    }
    frame.refresh(&second);

    var expected = first;
    for (stale) |region| {
        const byte_len = @as(usize, region.width) * 4;
        var row: u32 = 0;
        while (row < region.height) : (row += 1) {
            const offset = (@as(usize, region.y + row) * test_width + region.x) * 4;
            @memcpy(expected[offset..][0..byte_len], second[offset..][0..byte_len]);
        }
    }
    try std.testing.expectEqualSlices(u8, &expected, frame.contents());
}

test "invalidations accumulate until a refresh clears them" {
    var storage: [test_bytes]u8 = @splat(0);
    var frame = Frame{ .bytes = storage[0..] };
    _ = frame.resize(test_width, test_height);
    var source: [test_bytes]u8 = undefined;
    paint(&source, 7);
    frame.refresh(&source);

    const top_left = Region{ .x = 0, .y = 0, .width = 2, .height = 2 };
    const bottom_right = Region{ .x = 6, .y = 4, .width = 2, .height = 2 };
    try std.testing.expectEqual(damage.Addition.exact, frame.invalidate(top_left));
    try std.testing.expectEqual(damage.Addition.exact, frame.invalidate(bottom_right));
    try std.testing.expectEqualSlices(Region, &.{ top_left, bottom_right }, frame.dirty.slice());
    try std.testing.expectEqual(@as(usize, 8), frame.dirty.pixelCount());
    frame.refresh(&source);
    try std.testing.expect(frame.isCurrent());
    try std.testing.expect(frame.dirty.isEmpty());
}

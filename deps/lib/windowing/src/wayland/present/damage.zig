const std = @import("std");
const windowing = @import("../../root.zig");

const Rect = windowing.PresentRegion;

const frame_rect_count = 16;

pub const max_rects = frame_rect_count * (windowing.presentation.Limits{}).active_buffer_count;

const Count = std.math.IntFittingRange(0, max_rects);

/// The answer an addition gives. A caller that adds a rectangle reads the
/// answer to learn whether the accumulator still names the rectangles it was
/// given. `exact` says the list still names the rectangles added since the last
/// clear. By contrast, `collapsed` says the list now holds one rectangle
/// covering every rectangle it held and the one added.
pub const Addition = enum { exact, collapsed };

/// The list of rectangles that one destination still owes, the accumulator.
/// That destination is a buffer, the surface, or the retained frame. The list
/// sits in a fixed array of at most `max_rects` (48) entries with a count, so
/// the value carries its own storage and asks no allocator for more. The bound
/// of 48 is 16 rectangles for each of the three buffers a swapchain holds under
/// default limits.
///
/// The call `cover` puts one rectangle in the list spanning the whole extent.
/// The call `add` drops the listed rectangles the new one covers, and leaves
/// the list as it was when a listed rectangle already covers the new one. Two
/// overlapping rectangles stay as two entries when neither covers the other.
/// Each of the three readers of the list, `Acquired.write`, `Frame.refresh` and
/// `damageBuffer`, walks every entry, so a pixel two entries share is written,
/// copied or reported once for each of them.
///
/// As long as no collapse has happened, the list covers the whole extent after
/// a `cover`, and otherwise covers the union of the rectangles added since the
/// last clear, pixel for pixel. A list still holding all 48 entries after the
/// drop step collapses to the bounding box of the 48 and the new rectangle.
/// After a collapse, the list still covers every rectangle added since the last
/// clear, and it can cover more.
///
/// Any buffer the compositor has released may come back from the swapchain, so
/// the next write can land in a buffer whose pixels date from two or more
/// presents back. For that reason, every buffer keeps adding each presented
/// rectangle to its own list until a present brings it up to date, and that
/// present writes the listed rectangles before emptying the list. The surface
/// keeps a list of the same shape against the buffer the compositor last
/// received.
pub const Region = struct {
    rects: [max_rects]Rect = undefined,
    count: Count = 0,

    pub fn isEmpty(self: *const Region) bool {
        std.debug.assert(self.count <= max_rects);
        return self.count == 0;
    }

    pub fn slice(self: *const Region) []const Rect {
        std.debug.assert(self.count <= max_rects);
        return self.rects[0..self.count];
    }

    pub fn clear(self: *Region) void {
        self.count = 0;
    }

    /// Drops the list and puts one rectangle in it, spanning the extent given,
    /// so a caller that has invalidated the whole frame, as a resize does, says
    /// so in one entry. The width and the height each have to be above zero.
    pub fn cover(self: *Region, width: u32, height: u32) void {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        self.rects[0] = .{ .x = 0, .y = 0, .width = width, .height = height };
        self.count = 1;
    }

    /// Adds the rectangle `next` to the accumulator, so every report that part
    /// of the frame changed reaches that list. A rectangle with no area,
    /// meaning zero width or zero height, changes nothing and answers `.exact`.
    /// A rectangle a listed one already covers leaves the list as it was and
    /// answers `.exact`. Otherwise, the call drops every listed rectangle the
    /// new one covers. A list still holding all `max_rects` entries after that
    /// drop collapses to the bounding box of the `max_rects` and the new
    /// rectangle, and the call answers `.collapsed`. Otherwise, the call
    /// appends the rectangle and answers `.exact`.
    pub fn add(self: *Region, next: Rect) Addition {
        std.debug.assert(self.count <= max_rects);
        if (next.width == 0 or next.height == 0) return .exact;
        for (self.slice()) |entry| {
            if (contains(entry, next)) return .exact;
        }
        self.dropContained(next);
        if (self.count == max_rects) {
            self.collapse(next);
            return .collapsed;
        }
        self.rects[self.count] = next;
        self.count += 1;
        std.debug.assert(self.count > 0);
        std.debug.assert(self.count <= max_rects);
        return .exact;
    }

    pub fn pixelCount(self: *const Region) usize {
        var total: usize = 0;
        for (self.slice()) |entry| {
            std.debug.assert(entry.width > 0);
            std.debug.assert(entry.height > 0);
            total += entry.pixelCount();
        }
        return total;
    }

    fn dropContained(self: *Region, next: Rect) void {
        const before = self.count;
        var kept: Count = 0;
        for (self.rects[0..before]) |entry| {
            if (contains(next, entry)) continue;
            self.rects[kept] = entry;
            kept += 1;
        }
        std.debug.assert(kept <= before);
        self.count = kept;
    }

    fn collapse(self: *Region, next: Rect) void {
        std.debug.assert(self.count == max_rects);
        var bounds = next;
        for (self.slice()) |entry| bounds = boundingBox(bounds, entry);
        self.rects[0] = bounds;
        self.count = 1;
        std.debug.assert(contains(bounds, next));
    }
};

fn contains(outer: Rect, inner: Rect) bool {
    std.debug.assert(inner.width > 0);
    std.debug.assert(inner.height > 0);
    const outer_right = @as(u64, outer.x) + outer.width;
    const outer_bottom = @as(u64, outer.y) + outer.height;
    const inner_right = @as(u64, inner.x) + inner.width;
    const inner_bottom = @as(u64, inner.y) + inner.height;
    return outer.x <= inner.x and outer.y <= inner.y and
        inner_right <= outer_right and inner_bottom <= outer_bottom;
}

fn boundingBox(first: Rect, second: Rect) Rect {
    const x = @min(first.x, second.x);
    const y = @min(first.y, second.y);
    const right = @max(@as(u64, first.x) + first.width, @as(u64, second.x) + second.width);
    const bottom = @max(@as(u64, first.y) + first.height, @as(u64, second.y) + second.height);
    std.debug.assert(right > x);
    std.debug.assert(bottom > y);
    return .{
        .x = x,
        .y = y,
        .width = @intCast(right - x),
        .height = @intCast(bottom - y),
    };
}

test "an empty accumulator takes the first rectangle unchanged" {
    var owed = Region{};
    try std.testing.expect(owed.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), owed.slice().len);
    const empty = Rect{ .x = 4, .y = 3, .width = 0, .height = 9 };
    try std.testing.expectEqual(Addition.exact, owed.add(empty));
    try std.testing.expect(owed.isEmpty());
    const first = Rect{ .x = 4, .y = 3, .width = 6, .height = 5 };
    try std.testing.expectEqual(Addition.exact, owed.add(first));
    try std.testing.expectEqualSlices(Rect, &.{first}, owed.slice());
    try std.testing.expectEqual(@as(usize, 30), owed.pixelCount());
}

test "overlapping damage stays listed until one rectangle contains another" {
    const left = Rect{ .x = 2, .y = 4, .width = 8, .height = 6 };
    const right = Rect{ .x = 8, .y = 2, .width = 12, .height = 8 };
    var owed = Region{};
    try std.testing.expectEqual(Addition.exact, owed.add(left));
    try std.testing.expectEqual(Addition.exact, owed.add(right));
    try std.testing.expectEqualSlices(Rect, &.{ left, right }, owed.slice());
    try std.testing.expectEqual(@as(usize, 48 + 96), owed.pixelCount());

    const inside = Rect{ .x = 3, .y = 5, .width = 2, .height = 2 };
    try std.testing.expectEqual(Addition.exact, owed.add(inside));
    try std.testing.expectEqualSlices(Rect, &.{ left, right }, owed.slice());

    const spanning = Rect{ .x = 2, .y = 2, .width = 18, .height = 8 };
    try std.testing.expectEqual(Addition.exact, owed.add(spanning));
    try std.testing.expectEqualSlices(Rect, &.{spanning}, owed.slice());
}

test "covering and clearing bound the accumulator to the extent" {
    var owed = Region{};
    const outside = Rect{ .x = 30, .y = 20, .width = 2, .height = 2 };
    try std.testing.expectEqual(Addition.exact, owed.add(outside));
    owed.cover(16, 12);
    try std.testing.expectEqualSlices(Rect, &.{Rect.full(16, 12)}, owed.slice());
    try std.testing.expectEqual(@as(usize, 192), owed.pixelCount());
    owed.clear();
    try std.testing.expect(owed.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), owed.pixelCount());
}

fn spacedCell(index: usize) Rect {
    std.debug.assert(index < max_rects);
    return .{
        .x = @intCast(3 * (index % 8)),
        .y = @intCast(3 * (index / 8)),
        .width = 2,
        .height = 2,
    };
}

test "forty eight disjoint rectangles stay listed and a forty ninth collapses them" {
    try std.testing.expectEqual(@as(usize, 48), max_rects);
    try std.testing.expectEqual(
        max_rects * @sizeOf(Rect) + @alignOf(Rect),
        @sizeOf(Region),
    );
    var owed = Region{};
    for (0..max_rects) |index| {
        try std.testing.expectEqual(Addition.exact, owed.add(spacedCell(index)));
    }
    try std.testing.expectEqual(max_rects, owed.slice().len);
    try std.testing.expectEqual(max_rects * 4, owed.pixelCount());

    const last = Rect{ .x = 24, .y = 18, .width = 2, .height = 2 };
    try std.testing.expectEqual(Addition.collapsed, owed.add(last));
    try std.testing.expectEqualSlices(Rect, &.{Rect.full(26, 20)}, owed.slice());
    try std.testing.expectEqual(Addition.exact, owed.add(spacedCell(9)));
    try std.testing.expectEqualSlices(Rect, &.{Rect.full(26, 20)}, owed.slice());
}

const model_width: u32 = 16;
const model_height: u32 = 12;
const Mask = [model_width * model_height]bool;

fn markMask(mask: *Mask, rect: Rect) void {
    var row: u32 = 0;
    while (row < rect.height) : (row += 1) {
        const start = (rect.y + row) * model_width + rect.x;
        @memset(mask[start..][0..rect.width], true);
    }
}

fn boundsMask(mask: *const Mask) Mask {
    var bounds: ?Rect = null;
    for (mask, 0..) |set, index| {
        if (!set) continue;
        const pixel = Rect{
            .x = @intCast(index % model_width),
            .y = @intCast(index / model_width),
            .width = 1,
            .height = 1,
        };
        bounds = if (bounds) |value| boundingBox(value, pixel) else pixel;
    }
    var result: Mask = @splat(false);
    markMask(&result, bounds.?);
    return result;
}

fn drawModelRect(random: std.Random) Rect {
    const reach: u32 = if (random.uintLessThan(u8, 8) == 0) model_width else 3;
    const x = random.uintLessThan(u32, model_width);
    const y = random.uintLessThan(u32, model_height);
    return .{
        .x = x,
        .y = y,
        .width = 1 + random.uintLessThan(u32, @min(reach, model_width - x)),
        .height = 1 + random.uintLessThan(u32, @min(reach, model_height - y)),
    };
}

fn expectListInvariant(owed: *const Region, expected: *const Mask) !void {
    var covered: Mask = @splat(false);
    const entries = owed.slice();
    for (entries, 0..) |outer, outer_index| {
        markMask(&covered, outer);
        for (entries, 0..) |inner, inner_index| {
            if (outer_index == inner_index) continue;
            try std.testing.expect(!contains(outer, inner));
        }
    }
    try std.testing.expectEqualSlices(bool, expected, &covered);
}

test "listed rectangles cover exactly the pixels added since the last clear" {
    var prng = std.Random.DefaultPrng.init(0x7e96_1d0c_48a5_3b21);
    const random = prng.random();
    var exact_additions: usize = 0;
    var collapses: usize = 0;
    var owed = Region{};
    for (0..64) |_| {
        owed.clear();
        var added: Mask = @splat(false);
        var expected: Mask = @splat(false);
        for (0..96) |_| {
            const next = drawModelRect(random);
            const before = owed.slice().len;
            markMask(&added, next);
            markMask(&expected, next);
            switch (owed.add(next)) {
                .exact => exact_additions += 1,
                .collapsed => {
                    try std.testing.expectEqual(max_rects, before);
                    expected = boundsMask(&expected);
                    collapses += 1;
                },
            }
            try expectListInvariant(&owed, &expected);
            for (added, expected) |pixel, owes| {
                if (pixel) try std.testing.expect(owes);
            }
        }
    }
    try std.testing.expect(exact_additions > 0);
    try std.testing.expect(collapses > 0);
}

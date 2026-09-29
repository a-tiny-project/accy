const std = @import("std");

pub const Position = struct {
    line: usize = 0,
    column: usize = 0,
};

pub const Reset = struct {
    line_feeds: usize,
    trailing_cells: usize,
};

pub const Summary = union(enum) {
    inline_cells: usize,
    reset: Reset,

    pub fn fromBytes(bytes: []const u8) Summary {
        var line_feeds: usize = 0;
        var last_reset: ?usize = null;
        for (bytes, 0..) |byte, index| {
            switch (byte) {
                '\n' => {
                    line_feeds +|= 1;
                    last_reset = index;
                },
                '\r' => last_reset = index,
                else => {},
            }
        }
        const reset_index = last_reset orelse
            return .{ .inline_cells = bytes.len };
        return .{ .reset = .{
            .line_feeds = line_feeds,
            .trailing_cells = bytes.len - (reset_index + 1),
        } };
    }

    pub fn append(left: Summary, right: Summary) Summary {
        return switch (left) {
            .inline_cells => |left_cells| switch (right) {
                .inline_cells => |right_cells| .{
                    .inline_cells = left_cells +| right_cells,
                },
                .reset => right,
            },
            .reset => |left_reset| switch (right) {
                .inline_cells => |right_cells| .{ .reset = .{
                    .line_feeds = left_reset.line_feeds,
                    .trailing_cells = left_reset.trailing_cells +| right_cells,
                } },
                .reset => |right_reset| .{ .reset = .{
                    .line_feeds = left_reset.line_feeds +| right_reset.line_feeds,
                    .trailing_cells = right_reset.trailing_cells,
                } },
            },
        };
    }

    pub fn advance(self: Summary, start: Position) Position {
        return switch (self) {
            .inline_cells => |cells| .{
                .line = start.line,
                .column = start.column +| cells,
            },
            .reset => |reset| .{
                .line = start.line +| reset.line_feeds,
                .column = reset.trailing_cells,
            },
        };
    }

    pub fn flatWidth(self: Summary) ?usize {
        return switch (self) {
            .inline_cells => |cells| cells,
            .reset => null,
        };
    }
};

pub fn consumeFlatBytes(bytes: []const u8, budget: *usize) bool {
    if (bytes.len > budget.*) return false;
    if (std.mem.findAny(u8, bytes, "\r\n") != null) return false;
    budget.* -= bytes.len;
    return true;
}

test "flat byte consumption agrees with position summaries across byte values" {
    var bytes: [129]u8 = undefined;
    for (0..256) |value| {
        @memset(&bytes, @intCast(value));
        for (0..bytes.len + 1) |length| {
            const text = bytes[0..length];
            const width = Summary.fromBytes(text).flatWidth();
            for ([_]usize{ 0, length -| 1, length, length + 1, std.math.maxInt(usize) }) |limit| {
                var budget = limit;
                const fits = if (width) |cells| cells <= limit else false;
                try std.testing.expectEqual(fits, consumeFlatBytes(text, &budget));
                try std.testing.expectEqual(if (fits) limit - length else limit, budget);
            }
        }
    }
}

test "position summaries compose across split CRLF" {
    const left = Summary.fromBytes("ab\r");
    const right = Summary.fromBytes("\ncd");
    const whole = Summary.fromBytes("ab\r\ncd");
    try std.testing.expectEqual(whole, left.append(right));

    const start = Position{ .line = 7, .column = std.math.maxInt(usize) };
    try std.testing.expectEqual(
        whole.advance(start),
        right.advance(left.advance(start)),
    );
    try std.testing.expectEqual(
        Position{ .line = 8, .column = 2 },
        whole.advance(start),
    );
}

test "position advancement saturates additive fields" {
    const maximum = std.math.maxInt(usize);
    const start = Position{ .line = maximum, .column = maximum };
    try std.testing.expectEqual(
        start,
        (Summary{ .inline_cells = 1 }).advance(start),
    );
    try std.testing.expectEqual(
        Position{ .line = maximum, .column = maximum },
        (Summary{ .reset = .{
            .line_feeds = 1,
            .trailing_cells = maximum,
        } }).advance(start),
    );
    try std.testing.expectEqual(
        Summary{ .reset = .{
            .line_feeds = maximum,
            .trailing_cells = maximum,
        } },
        (Summary{ .reset = .{
            .line_feeds = maximum,
            .trailing_cells = maximum,
        } }).append(.{ .inline_cells = 1 }),
    );
}

test "flat byte consumption rejects every position reset" {
    var exact_budget: usize = 3;
    try std.testing.expect(consumeFlatBytes("abc", &exact_budget));
    try std.testing.expectEqual(@as(usize, 0), exact_budget);

    var line_feed_budget: usize = 3;
    try std.testing.expect(!consumeFlatBytes("a\nb", &line_feed_budget));
    try std.testing.expectEqual(@as(usize, 3), line_feed_budget);

    var carriage_return_budget: usize = 3;
    try std.testing.expect(!consumeFlatBytes("a\rb", &carriage_return_budget));
    try std.testing.expectEqual(@as(usize, 3), carriage_return_budget);
}

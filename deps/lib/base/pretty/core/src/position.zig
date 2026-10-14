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

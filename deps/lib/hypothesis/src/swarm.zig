const std = @import("std");
const conjecture = @import("conjecture.zig");

const ConjectureData = conjecture.ConjectureData;
const DrawError = conjecture.DrawError;

pub const Config = struct {
    min_active: u16 = 1,
    max_active: ?u16 = null,
    max_weight: u16 = 100,
};

pub fn Weights(comptime Action: type) type {
    const actions = actionTags(Action);
    return struct {
        values: [actions.len]u16,
        total: u64,

        const Self = @This();

        pub fn get(self: Self, action: Action) u16 {
            inline for (actions, 0..) |tag, index| {
                if (action == tag) return self.values[index];
            }
            unreachable;
        }

        pub fn activeCount(self: Self) usize {
            var count: usize = 0;
            for (self.values) |weight| {
                if (weight > 0) count += 1;
            }
            return count;
        }

        pub fn choose(self: Self, data: *ConjectureData) DrawError!Action {
            std.debug.assert(self.total > 0);
            var selection = try data.drawInteger(0, self.total - 1, 0);
            inline for (actions, 0..) |tag, index| {
                const weight = self.values[index];
                if (selection < weight) return tag;
                selection -= weight;
            }
            unreachable;
        }
    };
}

pub fn draw(
    comptime Action: type,
    data: *ConjectureData,
    config: Config,
) DrawError!Weights(Action) {
    const actions = actionTags(Action);
    const action_count: u16 = @intCast(actions.len);
    const max_active = @min(config.max_active orelse action_count, action_count);
    std.debug.assert(config.min_active > 0);
    std.debug.assert(config.min_active <= max_active);
    std.debug.assert(config.max_weight > 0);

    const active_target: u16 = @intCast(try data.drawInteger(
        config.min_active,
        max_active,
        config.min_active,
    ));
    var result = Weights(Action){
        .values = @splat(0),
        .total = 0,
    };
    var selected: u16 = 0;
    for (&result.values, 0..) |*value, index| {
        const remaining: u16 = action_count - @as(u16, @intCast(index));
        const needed = active_target - selected;
        const include = if (needed == 0)
            false
        else if (needed == remaining)
            true
        else
            try data.drawInteger(0, remaining - 1, 0) < needed;
        if (include) {
            const weight: u16 = @intCast(try data.drawInteger(1, config.max_weight, 1));
            value.* = weight;
            result.total += weight;
            selected += 1;
        }
    }
    std.debug.assert(selected == active_target);
    std.debug.assert(result.total > 0);
    return result;
}

fn actionTags(comptime Action: type) []const Action {
    const info = @typeInfo(Action);
    if (info != .@"enum") @compileError("swarm actions must be an enum");
    if (info.@"enum".mode != .exhaustive) {
        @compileError("swarm actions must be an exhaustive enum");
    }
    const tags = std.meta.tags(Action);
    if (tags.len == 0) @compileError("swarm actions cannot be empty");
    if (tags.len > std.math.maxInt(u16)) {
        @compileError("swarm actions exceed the supported count");
    }
    return tags;
}

const TestAction = enum {
    put,
    commit,
    checkpoint,
};

test "swarm: one run reuses one deterministic action distribution" {
    var left = ConjectureData.init(std.testing.allocator, 0x51a2_77);
    defer left.deinit();
    var right = ConjectureData.init(std.testing.allocator, 0x51a2_77);
    defer right.deinit();

    const left_weights = try draw(TestAction, &left, .{});
    const right_weights = try draw(TestAction, &right, .{});
    try std.testing.expectEqualDeep(left_weights, right_weights);
    for (0..32) |_| {
        try std.testing.expectEqual(
            try left_weights.choose(&left),
            try right_weights.choose(&right),
        );
    }
}

test "swarm: an active subset focuses every action in a run" {
    var nodes = [_]conjecture.ChoiceNode{
        .{ .kind = .integer, .value = 1 },
        .{ .kind = .integer, .value = 2 },
        .{ .kind = .integer, .value = 1 },
        .{ .kind = .integer, .value = 7 },
        .{ .kind = .integer, .value = 0 },
    };
    var data = ConjectureData.initReplay(std.testing.allocator, &nodes, null);
    defer data.deinit();

    const weights = try draw(TestAction, &data, .{ .min_active = 1, .max_active = 1 });
    try std.testing.expectEqual(@as(usize, 1), weights.activeCount());
    try std.testing.expectEqual(@as(u16, 0), weights.get(.put));
    try std.testing.expectEqual(@as(u16, 0), weights.get(.commit));
    try std.testing.expectEqual(@as(u16, 7), weights.get(.checkpoint));
    try std.testing.expectEqual(TestAction.checkpoint, try weights.choose(&data));
}

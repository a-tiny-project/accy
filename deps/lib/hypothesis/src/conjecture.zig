const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ChoiceKind = enum(u8) {
    integer,
    boolean,
    float,
    bytes,
};

pub const ChoiceNode = struct {
    kind: ChoiceKind,
    value: u64,
    min: u64 = 0,
    max: u64 = std.math.maxInt(u64),
    shrink_towards: u64 = 0,
    was_forced: bool = false,
};

pub const Span = struct {
    label: []const u8,
    start: usize,
    end: usize,
    depth: usize,
};

pub const Status = enum {
    valid,
    invalid,
    interesting,
    overrun,
};

pub const DrawError = error{
    Overrun,
    OutOfMemory,
};

pub const default_max_input_bytes: usize = 1024 * 1024;

pub const TargetError = error{
    DuplicateTargetLabel,
    NonFiniteTarget,
    OutOfMemory,
};

pub const TargetObservation = struct {
    label: []const u8,
    value: f64,
};

pub const ConjectureData = struct {
    choices: std.ArrayListUnmanaged(ChoiceNode) = .empty,
    spans: std.ArrayListUnmanaged(Span) = .empty,
    byte_blocks: std.ArrayListUnmanaged(u8) = .empty,
    targets: std.ArrayListUnmanaged(TargetObservation) = .empty,
    span_depth: usize = 0,
    status: Status = .valid,
    max_choices: usize = 4096,
    max_input_bytes: usize = default_max_input_bytes,

    prng: std.Random.DefaultPrng,

    replay_choices: ?[]const ChoiceNode = null,
    replay_byte_blocks: ?[]const u8 = null,
    replay_index: usize = 0,
    replay_byte_offset: usize = 0,

    allocator: Allocator,

    pub fn init(allocator: Allocator, seed: u64) ConjectureData {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .allocator = allocator,
        };
    }

    pub fn initReplay(
        allocator: Allocator,
        replay_choices: []const ChoiceNode,
        replay_byte_blocks: ?[]const u8,
    ) ConjectureData {
        return .{
            .prng = std.Random.DefaultPrng.init(0),
            .replay_choices = replay_choices,
            .replay_byte_blocks = replay_byte_blocks,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConjectureData) void {
        self.clearTargets();
        self.choices.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.byte_blocks.deinit(self.allocator);
        self.targets.deinit(self.allocator);
    }

    pub fn beginSpan(self: *ConjectureData, label: []const u8) !void {
        try self.spans.append(self.allocator, .{
            .label = label,
            .start = self.choices.items.len,
            .end = 0,
            .depth = self.span_depth,
        });
        self.span_depth += 1;
    }

    pub fn endSpan(self: *ConjectureData) void {
        std.debug.assert(self.span_depth > 0);
        self.span_depth -= 1;
        var i = self.spans.items.len;
        while (i > 0) {
            i -= 1;
            if (self.spans.items[i].depth == self.span_depth and
                self.spans.items[i].end == 0)
            {
                self.spans.items[i].end = self.choices.items.len;
                return;
            }
        }
    }

    pub fn drawInteger(
        self: *ConjectureData,
        min: u64,
        max: u64,
        shrink_towards: u64,
    ) DrawError!u64 {
        if (self.choices.items.len >= self.max_choices) {
            self.status = .overrun;
            return DrawError.Overrun;
        }

        const value = if (self.replay_choices) |replay| blk: {
            if (self.replay_index >= replay.len) {
                self.status = .overrun;
                return DrawError.Overrun;
            }
            const node = replay[self.replay_index];
            self.replay_index += 1;
            break :blk node.value;
        } else blk: {
            if (min == max) break :blk min;
            const range = max -% min;
            break :blk min +% self.prng.random().intRangeAtMost(u64, 0, range);
        };

        const clamped = @min(@max(value, min), max);

        try self.choices.append(self.allocator, .{
            .kind = .integer,
            .value = clamped,
            .min = min,
            .max = max,
            .shrink_towards = shrink_towards,
        });

        return clamped;
    }

    pub fn drawBoolean(self: *ConjectureData) DrawError!bool {
        const value = try self.drawInteger(0, 1, 0);
        return value != 0;
    }

    pub fn drawFloat(
        self: *ConjectureData,
        min: f64,
        max: f64,
    ) DrawError!f64 {
        if (self.choices.items.len >= self.max_choices) {
            self.status = .overrun;
            return DrawError.Overrun;
        }

        const value = if (self.replay_choices) |replay| blk: {
            if (self.replay_index >= replay.len) {
                self.status = .overrun;
                return DrawError.Overrun;
            }
            const node = replay[self.replay_index];
            self.replay_index += 1;
            break :blk @as(f64, @bitCast(node.value));
        } else blk: {
            const r = self.prng.random();
            const unit: f64 = @as(f64, @floatFromInt(r.int(u52))) /
                @as(f64, @floatFromInt(@as(u52, std.math.maxInt(u52))));
            break :blk min + unit * (max - min);
        };

        const clamped = @min(@max(value, min), max);

        try self.choices.append(self.allocator, .{
            .kind = .float,
            .value = @bitCast(clamped),
            .min = @bitCast(min),
            .max = @bitCast(max),
            .shrink_towards = @bitCast(@as(f64, 0.0)),
        });

        return clamped;
    }

    pub fn drawBytes(
        self: *ConjectureData,
        min_size: usize,
        max_size: usize,
    ) DrawError![]const u8 {
        const len = try self.drawInteger(
            @intCast(min_size),
            @intCast(max_size),
            @intCast(min_size),
        );

        const start = self.byte_blocks.items.len;
        const size: usize = @intCast(len);
        std.debug.assert(start <= self.max_input_bytes);
        if (size > self.max_input_bytes - start) {
            self.status = .overrun;
            return DrawError.Overrun;
        }

        if (self.replay_byte_blocks) |replay_bytes| {
            if (self.replay_byte_offset + size > replay_bytes.len) {
                self.status = .overrun;
                return DrawError.Overrun;
            }
            try self.byte_blocks.appendSlice(
                self.allocator,
                replay_bytes[self.replay_byte_offset..][0..size],
            );
            self.replay_byte_offset += size;
        } else {
            try self.byte_blocks.ensureUnusedCapacity(self.allocator, size);
            for (0..size) |_| {
                self.byte_blocks.appendAssumeCapacity(
                    self.prng.random().int(u8),
                );
            }
        }

        return self.byte_blocks.items[start..][0..size];
    }

    pub fn forceInteger(self: *ConjectureData, value: u64) DrawError!void {
        if (self.choices.items.len >= self.max_choices) {
            self.status = .overrun;
            return DrawError.Overrun;
        }
        try self.choices.append(self.allocator, .{
            .kind = .integer,
            .value = value,
            .min = value,
            .max = value,
            .shrink_towards = value,
            .was_forced = true,
        });
    }

    pub fn target(self: *ConjectureData, observation: anytype, label: []const u8) TargetError!void {
        const value = targetValue(@TypeOf(observation), observation);
        if (!std.math.isFinite(value)) return TargetError.NonFiniteTarget;
        for (self.targets.items) |existing| {
            if (std.mem.eql(u8, existing.label, label)) {
                return TargetError.DuplicateTargetLabel;
            }
        }
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        try self.targets.append(self.allocator, .{
            .label = owned_label,
            .value = value,
        });
    }

    pub fn targetDefault(self: *ConjectureData, observation: anytype) TargetError!void {
        return self.target(observation, "");
    }

    pub fn markInteresting(self: *ConjectureData) void {
        self.status = .interesting;
    }

    pub fn markInvalid(self: *ConjectureData) void {
        self.status = .invalid;
    }

    pub fn reset(self: *ConjectureData, seed: u64) void {
        self.clearTargets();
        self.choices.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.byte_blocks.clearRetainingCapacity();
        self.span_depth = 0;
        self.status = .valid;
        self.prng = std.Random.DefaultPrng.init(seed);
        self.replay_choices = null;
        self.replay_byte_blocks = null;
        self.replay_index = 0;
        self.replay_byte_offset = 0;
    }

    pub fn resetReplay(
        self: *ConjectureData,
        replay_choices: []const ChoiceNode,
        replay_byte_blocks: ?[]const u8,
    ) void {
        self.clearTargets();
        self.choices.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.byte_blocks.clearRetainingCapacity();
        self.span_depth = 0;
        self.status = .valid;
        self.replay_choices = replay_choices;
        self.replay_byte_blocks = replay_byte_blocks;
        self.replay_index = 0;
        self.replay_byte_offset = 0;
    }

    fn clearTargets(self: *ConjectureData) void {
        for (self.targets.items) |target_observation| {
            self.allocator.free(target_observation.label);
        }
        self.targets.clearRetainingCapacity();
    }
};

pub fn target(data: *ConjectureData, observation: anytype, label: []const u8) TargetError!void {
    return data.target(observation, label);
}

fn targetValue(comptime T: type, value: T) f64 {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("target observation must be an integer or float"),
    };
}

test "drawInteger produces values in range" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    for (0..100) |_| {
        const v = try data.drawInteger(10, 20, 10);
        try std.testing.expect(v >= 10 and v <= 20);
    }
}

test "drawBoolean produces booleans" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    var saw_true = false;
    var saw_false = false;
    for (0..100) |_| {
        const v = try data.drawBoolean();
        if (v) saw_true = true else saw_false = true;
    }
    try std.testing.expect(saw_true and saw_false);
}

test "target records finite labeled observations" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    try data.target(12, "size");
    try data.target(-3.5, "distance");

    try std.testing.expectEqual(@as(usize, 2), data.targets.items.len);
    try std.testing.expectEqualStrings("size", data.targets.items[0].label);
    try std.testing.expectEqual(@as(f64, 12.0), data.targets.items[0].value);
    try std.testing.expectEqualStrings("distance", data.targets.items[1].label);
    try std.testing.expectEqual(@as(f64, -3.5), data.targets.items[1].value);
}

test "target rejects duplicate labels and non-finite observations" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    try data.target(1, "score");
    try std.testing.expectError(TargetError.DuplicateTargetLabel, data.target(2, "score"));
    try std.testing.expectError(TargetError.NonFiniteTarget, data.target(std.math.inf(f64), "inf"));
}

test "replay reproduces values" {
    const allocator = std.testing.allocator;

    var gen = ConjectureData.init(allocator, 123);
    defer gen.deinit();
    const v1 = try gen.drawInteger(0, 100, 0);
    const v2 = try gen.drawInteger(0, 100, 0);
    const v3 = try gen.drawBoolean();

    var replay = ConjectureData.initReplay(allocator, gen.choices.items, null);
    defer replay.deinit();
    try std.testing.expectEqual(v1, try replay.drawInteger(0, 100, 0));
    try std.testing.expectEqual(v2, try replay.drawInteger(0, 100, 0));
    try std.testing.expectEqual(v3, try replay.drawBoolean());
}

test "overrun on too many choices" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();
    data.max_choices = 5;

    for (0..5) |_| {
        _ = try data.drawInteger(0, 10, 0);
    }
    try std.testing.expectError(DrawError.Overrun, data.drawInteger(0, 10, 0));
    try std.testing.expectEqual(.overrun, data.status);
}

test "span tracking" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    try data.beginSpan("outer");
    _ = try data.drawInteger(0, 10, 0);
    try data.beginSpan("inner");
    _ = try data.drawInteger(0, 10, 0);
    data.endSpan();
    _ = try data.drawInteger(0, 10, 0);
    data.endSpan();

    try std.testing.expectEqual(2, data.spans.items.len);
    try std.testing.expectEqual(1, data.spans.items[1].start);
    try std.testing.expectEqual(2, data.spans.items[1].end);
    try std.testing.expectEqual(1, data.spans.items[1].depth);
    try std.testing.expectEqual(0, data.spans.items[0].start);
    try std.testing.expectEqual(3, data.spans.items[0].end);
    try std.testing.expectEqual(0, data.spans.items[0].depth);
}

test "drawFloat produces values in range" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    for (0..100) |_| {
        const v = try data.drawFloat(-1.0, 1.0);
        try std.testing.expect(v >= -1.0 and v <= 1.0);
    }
}

test "drawBytes produces bytes in size range" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    for (0..20) |_| {
        const bs = try data.drawBytes(2, 8);
        try std.testing.expect(bs.len >= 2 and bs.len <= 8);
    }
}

test "drawBytes rejects cumulative max input plus one without growing bytes" {
    var data = ConjectureData.init(std.testing.allocator, 42);
    defer data.deinit();
    data.max_input_bytes = 4;
    _ = try data.drawBytes(2, 2);
    _ = try data.drawBytes(2, 2);
    const pointer = data.byte_blocks.items.ptr;
    try std.testing.expectError(DrawError.Overrun, data.drawBytes(1, 1));
    try std.testing.expectEqual(Status.overrun, data.status);
    try std.testing.expectEqual(@as(usize, 4), data.byte_blocks.items.len);
    try std.testing.expectEqual(pointer, data.byte_blocks.items.ptr);
}

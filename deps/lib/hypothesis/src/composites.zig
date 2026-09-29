const std = @import("std");
const Allocator = std.mem.Allocator;
const conjecture = @import("conjecture.zig");
const ConjectureData = conjecture.ConjectureData;
const DrawError = conjecture.DrawError;
const engine = @import("engine.zig");
const strategy_mod = @import("strategy.zig");
const Strategy = strategy_mod.Strategy;

pub fn ListStrategy(comptime T: type) type {
    return struct {
        element: Strategy(T),
        min_len: usize,
        max_len: usize,

        const Self = @This();

        pub fn draw(self: *const Self, data: *ConjectureData, allocator: Allocator) DrawError![]const T {
            try data.beginSpan("list");

            var items = std.ArrayListUnmanaged(T).empty;
            errdefer items.deinit(allocator);

            for (0..self.min_len) |_| {
                const item = try self.element.draw(data, allocator);
                try items.append(allocator, item);
            }

            while (items.items.len < self.max_len) {
                const more = try data.drawBoolean();
                if (!more) break;
                const item = try self.element.draw(data, allocator);
                try items.append(allocator, item);
            }

            data.endSpan();
            return items.items;
        }

        pub fn strategy(self: *const Self) Strategy([]const T) {
            return Strategy([]const T).from(Self, self);
        }
    };
}

pub fn lists(comptime T: type, element: Strategy(T)) ListStrategy(T) {
    return listsWithLength(T, element, 0, 50);
}

pub fn listsWithLength(comptime T: type, element: Strategy(T), min_len: usize, max_len: usize) ListStrategy(T) {
    return .{
        .element = element,
        .min_len = min_len,
        .max_len = max_len,
    };
}

pub const StringStrategy = struct {
    charset: []const u8,
    min_len: usize,
    max_len: usize,

    pub fn draw(self: *const StringStrategy, data: *ConjectureData, allocator: Allocator) DrawError![]const u8 {
        std.debug.assert(self.charset.len > 0);
        std.debug.assert(self.min_len <= self.max_len);
        try data.beginSpan("string");

        var items = std.ArrayListUnmanaged(u8).empty;
        errdefer items.deinit(allocator);

        for (0..self.min_len) |_| {
            const ch = try strategy_mod.drawCharFromCharset(data, self.charset);
            try items.append(allocator, ch);
        }

        while (items.items.len < self.max_len) {
            const more = try data.drawBoolean();
            if (!more) break;
            const ch = try strategy_mod.drawCharFromCharset(data, self.charset);
            try items.append(allocator, ch);
        }

        data.endSpan();
        return items.items;
    }

    pub fn strategy(self: *const StringStrategy) Strategy([]const u8) {
        return Strategy([]const u8).from(StringStrategy, self);
    }
};

pub fn strings(charset: []const u8, min_len: usize, max_len: usize) StringStrategy {
    std.debug.assert(charset.len > 0);
    std.debug.assert(min_len <= max_len);
    return .{
        .charset = charset,
        .min_len = min_len,
        .max_len = max_len,
    };
}

pub fn asciiStrings(min_len: usize, max_len: usize) StringStrategy {
    return strings(strategy_mod.ascii_printable, min_len, max_len);
}

pub fn alphanumeric(min_len: usize, max_len: usize) StringStrategy {
    return strings(strategy_mod.alphanumeric, min_len, max_len);
}

pub fn urlSafeTokens(min_len: usize, max_len: usize) StringStrategy {
    return strings(strategy_mod.url_safe_tokens, min_len, max_len);
}

pub const SplitPointsStrategy = struct {
    total_len: usize,

    pub fn draw(self: *const SplitPointsStrategy, data: *ConjectureData, allocator: Allocator) DrawError![]const usize {
        try data.beginSpan("split_points");

        var items = std.ArrayListUnmanaged(usize).empty;
        errdefer items.deinit(allocator);

        const max_points: usize = self.total_len + 1;
        const count_raw = try data.drawInteger(0, @intCast(max_points), 0);
        const count: usize = @intCast(count_raw);

        var prev: usize = 0;
        for (0..count) |i| {
            const remaining = count - i - 1;
            const min_val: usize = if (i == 0) 0 else prev + 1;
            const max_val: usize = self.total_len - remaining;
            const raw = try data.drawInteger(@intCast(min_val), @intCast(max_val), @intCast(min_val));
            const val: usize = @intCast(raw);
            try items.append(allocator, val);
            prev = val;
        }

        data.endSpan();
        return items.items;
    }

    pub fn strategy(self: *const SplitPointsStrategy) Strategy([]const usize) {
        return Strategy([]const usize).from(SplitPointsStrategy, self);
    }
};

pub fn splitPoints(total_len: usize) SplitPointsStrategy {
    return .{ .total_len = total_len };
}

pub const PermutationStrategy = struct {
    count: usize,

    pub fn draw(self: *const PermutationStrategy, data: *ConjectureData, allocator: Allocator) DrawError![]const usize {
        try data.beginSpan("permutation");
        defer data.endSpan();

        const items = try allocator.alloc(usize, self.count);
        errdefer allocator.free(items);

        for (items, 0..) |*slot, idx| {
            slot.* = idx;
        }

        if (self.count <= 1) return items;

        var i: usize = 0;
        while (i + 1 < self.count) : (i += 1) {
            const j_raw = try data.drawInteger(@intCast(i), @intCast(self.count - 1), @intCast(i));
            const j: usize = @intCast(j_raw);
            if (j != i) {
                const tmp = items[i];
                items[i] = items[j];
                items[j] = tmp;
            }
        }

        return items;
    }

    pub fn strategy(self: *const PermutationStrategy) Strategy([]const usize) {
        return Strategy([]const usize).from(PermutationStrategy, self);
    }
};

pub fn permutations(count: usize) PermutationStrategy {
    return .{ .count = count };
}

pub fn ShuffleStrategy(comptime T: type) type {
    return struct {
        source: []const T,

        const Self = @This();

        pub fn draw(self: *const Self, data: *ConjectureData, allocator: Allocator) DrawError![]const T {
            try data.beginSpan("shuffle");
            defer data.endSpan();

            const out = try allocator.alloc(T, self.source.len);
            errdefer allocator.free(out);
            @memcpy(out, self.source);

            if (self.source.len <= 1) return out;

            var i: usize = 0;
            while (i + 1 < self.source.len) : (i += 1) {
                const j_raw = try data.drawInteger(@intCast(i), @intCast(self.source.len - 1), @intCast(i));
                const j: usize = @intCast(j_raw);
                if (j != i) {
                    const tmp = out[i];
                    out[i] = out[j];
                    out[j] = tmp;
                }
            }

            return out;
        }

        pub fn strategy(self: *const Self) Strategy([]const T) {
            return Strategy([]const T).from(Self, self);
        }
    };
}

pub fn shuffle(comptime T: type, slice: []const T) ShuffleStrategy(T) {
    return .{ .source = slice };
}

pub fn OptionalStrategy(comptime T: type) type {
    return struct {
        inner: Strategy(T),

        const Self = @This();

        pub fn draw(self: *const Self, data: *ConjectureData, allocator: Allocator) DrawError!?T {
            const present = try data.drawBoolean();
            if (!present) return null;
            return try self.inner.draw(data, allocator);
        }

        pub fn strategy(self: *const Self) Strategy(?T) {
            return Strategy(?T).from(Self, self);
        }
    };
}

pub fn optionals(comptime T: type, inner: Strategy(T)) OptionalStrategy(T) {
    return .{ .inner = inner };
}

pub fn OneOfStrategy(comptime T: type, comptime N: usize) type {
    return struct {
        alternatives: [N]Strategy(T),

        const Self = @This();

        pub fn draw(self: *const Self, data: *ConjectureData, allocator: Allocator) DrawError!T {
            const idx = try data.drawInteger(0, N - 1, 0);
            return self.alternatives[@intCast(idx)].draw(data, allocator);
        }

        pub fn strategy(self: *const Self) Strategy(T) {
            return Strategy(T).from(Self, self);
        }
    };
}

pub fn oneOf(comptime T: type, comptime N: usize, alternatives: [N]Strategy(T)) OneOfStrategy(T, N) {
    return .{ .alternatives = alternatives };
}

pub fn MapStrategy(comptime From: type, comptime To: type) type {
    return struct {
        source: Strategy(From),
        mapFn: *const fn (From) To,

        const Self = @This();

        pub fn draw(self: *const Self, data: *ConjectureData, allocator: Allocator) DrawError!To {
            const from_val = try self.source.draw(data, allocator);
            return self.mapFn(from_val);
        }

        pub fn strategy(self: *const Self) Strategy(To) {
            return Strategy(To).from(Self, self);
        }
    };
}

pub fn map(comptime From: type, comptime To: type, source: Strategy(From), mapFn: *const fn (From) To) MapStrategy(From, To) {
    return .{
        .source = source,
        .mapFn = mapFn,
    };
}

pub fn FilterStrategy(comptime T: type) type {
    return struct {
        source: Strategy(T),
        predFn: *const fn (T) bool,
        max_retries: usize,

        const Self = @This();

        pub fn draw(self: *const Self, data: *ConjectureData, allocator: Allocator) DrawError!T {
            for (0..self.max_retries) |_| {
                const val = try self.source.draw(data, allocator);
                if (self.predFn(val)) return val;
                data.markInvalid();
            }
            return self.source.draw(data, allocator);
        }

        pub fn strategy(self: *const Self) Strategy(T) {
            return Strategy(T).from(Self, self);
        }
    };
}

pub fn filter(comptime T: type, source: Strategy(T), predFn: *const fn (T) bool) FilterStrategy(T) {
    return filterWithRetries(T, source, predFn, 100);
}

pub fn filterWithRetries(
    comptime T: type,
    source: Strategy(T),
    predFn: *const fn (T) bool,
    max_retries: usize,
) FilterStrategy(T) {
    return .{
        .source = source,
        .predFn = predFn,
        .max_retries = max_retries,
    };
}

pub fn FlatMapStrategy(comptime From: type, comptime To: type) type {
    return struct {
        source: Strategy(From),
        bindFn: *const fn (From, Allocator) Strategy(To),

        const Self = @This();

        pub fn draw(self: *const Self, data: *ConjectureData, allocator: Allocator) DrawError!To {
            const from_val = try self.source.draw(data, allocator);
            const to_strategy = self.bindFn(from_val, allocator);
            return to_strategy.draw(data, allocator);
        }

        pub fn strategy(self: *const Self) Strategy(To) {
            return Strategy(To).from(Self, self);
        }
    };
}

pub fn flatMap(
    comptime From: type,
    comptime To: type,
    source: Strategy(From),
    bindFn: *const fn (From, Allocator) Strategy(To),
) FlatMapStrategy(From, To) {
    return .{
        .source = source,
        .bindFn = bindFn,
    };
}

test "lists strategy draws lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const elem = strategy_mod.integers(u8, 0, 255);
    const s = lists(u8, elem.strategy());
    for (0..10) |_| {
        const xs = try s.strategy().draw(&data, allocator);
        for (xs) |x| {
            try std.testing.expect(x <= 255);
        }
    }
}

test "string strategy draws strings in charset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data = ConjectureData.init(allocator, 4242);
    defer data.deinit();

    const charset = "ab01";
    const s = strings(charset, 2, 8);
    for (0..40) |_| {
        const value = try s.strategy().draw(&data, allocator);
        try std.testing.expect(value.len >= 2 and value.len <= 8);
        for (value) |ch| {
            try std.testing.expect(std.mem.indexOfScalar(u8, charset, ch) != null);
        }
    }
}

test "asciiStrings draws printable ASCII" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data = ConjectureData.init(allocator, 123);
    defer data.deinit();

    const s = asciiStrings(0, 12);
    for (0..40) |_| {
        const value = try s.strategy().draw(&data, allocator);
        try std.testing.expect(value.len <= 12);
        for (value) |ch| {
            try std.testing.expect(std.mem.indexOfScalar(u8, strategy_mod.ascii_printable, ch) != null);
        }
    }
}

test "splitPoints strategy draws sorted indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data = ConjectureData.init(allocator, 2026);
    defer data.deinit();

    const total_len: usize = 12;
    const s = splitPoints(total_len);
    for (0..50) |_| {
        const splits = try s.strategy().draw(&data, allocator);
        var last: usize = 0;
        for (splits, 0..) |val, idx| {
            try std.testing.expect(val <= total_len);
            if (idx > 0) try std.testing.expect(val > last);
            last = val;
        }
        try std.testing.expect(splits.len <= total_len + 1);
    }
}

test "permutations strategy draws permutations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data = ConjectureData.init(allocator, 2027);
    defer data.deinit();

    const count: usize = 7;
    const s = permutations(count);
    for (0..50) |_| {
        const perm = try s.strategy().draw(&data, allocator);
        try std.testing.expectEqual(count, perm.len);

        var seen = @as([count]bool, @splat(false));
        for (perm) |val| {
            try std.testing.expect(val < count);
            if (seen[val]) return error.TestFailure;
            seen[val] = true;
        }
        for (seen) |flag| {
            try std.testing.expect(flag);
        }
    }
}

test "shuffle strategy returns shuffled copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data = ConjectureData.init(allocator, 5150);
    defer data.deinit();

    const source = [_]u8{ 1, 2, 3, 4, 5 };
    const s = shuffle(u8, source[0..]);
    for (0..40) |_| {
        const out = try s.strategy().draw(&data, allocator);
        try std.testing.expectEqual(source.len, out.len);

        var seen = @as([source.len]bool, @splat(false));
        for (out) |val| {
            var idx_opt: ?usize = null;
            for (source, 0..) |orig, idx| {
                if (orig == val) {
                    idx_opt = idx;
                    break;
                }
            }
            const idx = idx_opt orelse return error.TestFailure;
            if (seen[idx]) return error.TestFailure;
            seen[idx] = true;
        }
        for (seen) |flag| {
            try std.testing.expect(flag);
        }
    }
}

test "optionals strategy draws optionals" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const inner = strategy_mod.integers(i32, 0, 100);
    const s = optionals(i32, inner.strategy());
    var saw_null = false;
    var saw_some = false;
    for (0..100) |_| {
        const v = try s.strategy().draw(&data, allocator);
        if (v) |_| saw_some = true else saw_null = true;
    }
    try std.testing.expect(saw_null and saw_some);
}

test "oneOf strategy selects from alternatives" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const small = strategy_mod.integers(i32, 0, 10);
    const big = strategy_mod.integers(i32, 1000, 2000);
    const s = oneOf(i32, 2, .{ small.strategy(), big.strategy() });

    var saw_small = false;
    var saw_big = false;
    for (0..100) |_| {
        const v = try s.strategy().draw(&data, allocator);
        if (v <= 10) saw_small = true;
        if (v >= 1000) saw_big = true;
    }
    try std.testing.expect(saw_small and saw_big);
}

const DoubleI32MapFixture = struct {
    fn f(x: i32) i32 {
        return x * 2;
    }
};

const EvenI32FilterFixture = struct {
    fn f(x: i32) bool {
        return @mod(x, 2) == 0;
    }
};

test "map strategy transforms values" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const source = strategy_mod.integers(i32, 1, 10);
    const doubled = map(i32, i32, source.strategy(), &DoubleI32MapFixture.f);

    for (0..50) |_| {
        const v = try doubled.strategy().draw(&data, allocator);
        try std.testing.expect(v >= 2 and v <= 20);
        try std.testing.expect(@mod(v, 2) == 0);
    }
}

test "filter strategy filters values" {
    const allocator = std.testing.allocator;
    var data = ConjectureData.init(allocator, 42);
    defer data.deinit();

    const source = strategy_mod.integers(i32, 0, 100);
    const evens = filter(i32, source.strategy(), &EvenI32FilterFixture.f);

    for (0..50) |_| {
        const v = try evens.strategy().draw(&data, allocator);
        _ = v;
    }
}

const UrlSafeTokenPropertyFixture = struct {
    fn property(data: *ConjectureData, gpa: Allocator) anyerror!void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const s = urlSafeTokens(0, 24);
        const value = try s.strategy().draw(data, arena_alloc);
        for (value) |ch| {
            if (std.mem.indexOfScalar(u8, strategy_mod.url_safe_tokens, ch) == null) {
                return error.PropertyFailed;
            }
        }
    }
};

test "string strategy property uses engine" {
    const allocator = std.testing.allocator;
    const settings = engine.Settings{ .max_examples = 100, .seed = 77 };

    var result = try engine.run(allocator, &UrlSafeTokenPropertyFixture.property, settings);
    defer result.deinit();
    try std.testing.expect(result.passed);
}

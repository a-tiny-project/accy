//! Balanced shard assignment. Every shard reads the same weights table and computes the
//! same longest-processing-time-first assignment over the binary's selected tests, then
//! runs only its own share. Coverage and disjointness follow from every shard evaluating
//! one pure function, and the merge step checks both.
const std = @import("std");

pub const header = "tiny-timing-weights-v1";
/// Matches the timing runner's bound on test functions in one binary.
pub const max_tests: usize = 16 * 1024;
pub const max_shards: usize = 32;
pub const max_name_bytes: usize = 1024;
/// Bounds the table file: one row per test at the longest name and a 20-digit weight.
pub const max_table_bytes: usize = max_tests * (max_name_bytes + 22) + 64;

/// Recorded microseconds per test name, sorted by name, plus the time each shard process
/// spends before its first test (shared setup that a `[tiny-test-shard-warmup]` test pays).
pub const Table = struct {
    shard_us: u64 = 0,
    names: []const []const u8 = &.{},
    micros: []const u64 = &.{},

    pub fn find(self: *const Table, name: []const u8) ?u64 {
        std.debug.assert(self.names.len == self.micros.len);
        std.debug.assert(self.names.len <= max_tests);
        var low: usize = 0;
        var high: usize = self.names.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, self.names[middle], name)) {
                .eq => return self.micros[middle],
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        std.debug.assert(low == high);
        return null;
    }

    /// The weight an unrecorded test receives: the table's mean, or 1 for an empty table.
    pub fn fallback(self: *const Table) u64 {
        std.debug.assert(self.names.len == self.micros.len);
        if (self.micros.len == 0) return 1;
        var sum: u64 = 0;
        for (self.micros) |value| sum +|= value;
        return @max(1, sum / self.micros.len);
    }

    pub fn weight(self: *const Table, name: []const u8) u64 {
        return self.find(name) orelse self.fallback();
    }
};

pub const ParseError = error{
    MissingHeader,
    InvalidHeader,
    InvalidRow,
    NameTooLong,
    Unsorted,
    TooManyRows,
};

/// Parses `header\t<shard_us>` then `<name>\t<microseconds>` rows in strictly ascending
/// name order. Names borrow `text`. The storage slices bound the row count.
pub fn parse(
    text: []const u8,
    names_storage: [][]const u8,
    micros_storage: []u64,
) ParseError!Table {
    std.debug.assert(names_storage.len == micros_storage.len);
    std.debug.assert(names_storage.len <= max_tests);
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next().?;
    if (first.len == 0) return error.MissingHeader;
    const first_tab = std.mem.indexOfScalar(u8, first, '\t') orelse return error.InvalidHeader;
    if (!std.mem.eql(u8, first[0..first_tab], header)) return error.InvalidHeader;
    const shard_us = std.fmt.parseUnsigned(u64, first[first_tab + 1 ..], 10) catch
        return error.InvalidHeader;
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (lines.peek() == null) break;
            return error.InvalidRow;
        }
        const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse return error.InvalidRow;
        const name = line[0..tab];
        if (name.len == 0) return error.InvalidRow;
        if (name.len > max_name_bytes) return error.NameTooLong;
        const micros = std.fmt.parseUnsigned(u64, line[tab + 1 ..], 10) catch
            return error.InvalidRow;
        if (count == names_storage.len) return error.TooManyRows;
        if (count != 0 and std.mem.order(u8, names_storage[count - 1], name) != .lt)
            return error.Unsorted;
        std.debug.assert(count < names_storage.len);
        names_storage[count] = name;
        micros_storage[count] = micros;
        count += 1;
    }
    return .{
        .shard_us = shard_us,
        .names = names_storage[0..count],
        .micros = micros_storage[0..count],
    };
}

/// Caller-owned working memory for one assignment, each slice at least the selected count.
pub const Scratch = struct {
    order: []u32,
    weights: []u64,
};

const Heaviest = struct {
    names: []const []const u8,
    weights: []const u64,

    fn before(self: Heaviest, a: u32, b: u32) bool {
        std.debug.assert(a < self.weights.len);
        std.debug.assert(b < self.weights.len);
        if (self.weights[a] != self.weights[b]) return self.weights[a] > self.weights[b];
        return std.mem.order(u8, self.names[a], self.names[b]) == .lt;
    }
};

/// Assigns each selected test to the least-loaded shard, heaviest first, with ties broken
/// by name and then by the lower shard index. Writes the selection ordinals that shard
/// `index` runs, heaviest first, into `out` and returns them.
pub fn assign(
    table: *const Table,
    names: []const []const u8,
    count: usize,
    index: usize,
    scratch: Scratch,
    out: []u32,
) []const u32 {
    std.debug.assert(count > 0);
    std.debug.assert(count <= max_shards);
    std.debug.assert(index < count);
    std.debug.assert(names.len <= max_tests);
    std.debug.assert(scratch.order.len >= names.len);
    std.debug.assert(scratch.weights.len >= names.len);
    std.debug.assert(out.len >= names.len);
    const order = scratch.order[0..names.len];
    const weights = scratch.weights[0..names.len];
    for (names, order, weights, 0..) |name, *slot, *value, ordinal| {
        slot.* = @intCast(ordinal);
        value.* = table.weight(name);
    }
    std.sort.pdq(u32, order, Heaviest{ .names = names, .weights = weights }, Heaviest.before);
    var loads: [max_shards]u64 = @splat(0);
    var assigned: usize = 0;
    for (order) |ordinal| {
        var lightest: usize = 0;
        for (loads[1..count], 1..) |load, shard| {
            if (load < loads[lightest]) lightest = shard;
        }
        std.debug.assert(lightest < count);
        loads[lightest] +|= weights[ordinal];
        if (lightest != index) continue;
        out[assigned] = ordinal;
        assigned += 1;
    }
    std.debug.assert(assigned <= names.len);
    return out[0..assigned];
}

fn expectAssignment(
    table: *const Table,
    names: []const []const u8,
    count: usize,
    expected: []const []const u32,
) !void {
    var order: [16]u32 = undefined;
    var weights: [16]u64 = undefined;
    var out: [16]u32 = undefined;
    const scratch = Scratch{ .order = &order, .weights = &weights };
    for (expected, 0..) |shard, index| {
        const actual = assign(table, names, count, index, scratch, &out);
        try std.testing.expectEqualSlices(u32, shard, actual);
    }
}

test "longest processing time first fills the lightest shard" {
    const names = [_][]const u8{ "a", "b", "c", "d", "e" };
    const micros = [_]u64{ 5, 4, 3, 3, 3 };
    const table = Table{ .names = &names, .micros = &micros };
    try expectAssignment(&table, &names, 2, &.{ &.{ 0, 3 }, &.{ 1, 2, 4 } });
}

test "every selected test lands on exactly one shard, whatever the selection order" {
    const names = [_][]const u8{ "t0", "t1", "t2", "t3", "t4", "t5", "t6" };
    const micros = [_]u64{ 9, 1, 7, 7, 2, 30, 4 };
    const table = Table{ .names = &names, .micros = &micros };
    const permuted = [_][]const u8{ "t5", "t2", "t0", "t6", "t1", "t4", "t3" };
    var order: [16]u32 = undefined;
    var weights: [16]u64 = undefined;
    var out: [16]u32 = undefined;
    const scratch = Scratch{ .order = &order, .weights = &weights };
    for (1..5) |count| {
        var seen: [names.len]u8 = @splat(0);
        var members: [names.len]usize = undefined;
        for (0..count) |index| {
            const straight = assign(&table, &names, count, index, scratch, &out);
            for (straight) |ordinal| {
                seen[ordinal] += 1;
                members[ordinal] = index;
            }
        }
        for (0..count) |index| {
            const shuffled = assign(&table, &permuted, count, index, scratch, &out);
            for (shuffled) |ordinal| {
                const original = for (names, 0..) |name, position| {
                    if (std.mem.eql(u8, name, permuted[ordinal])) break position;
                } else unreachable;
                try std.testing.expectEqual(index, members[original]);
            }
        }
        for (seen) |times| try std.testing.expectEqual(@as(u8, 1), times);
    }
}

test "an unrecorded test weighs the table mean" {
    const names = [_][]const u8{ "a", "b" };
    const micros = [_]u64{ 10, 30 };
    const table = Table{ .names = &names, .micros = &micros };
    try std.testing.expectEqual(@as(u64, 20), table.weight("new"));
    try std.testing.expectEqual(@as(u64, 30), table.weight("b"));
    try std.testing.expectEqual(@as(u64, 1), (Table{}).fallback());
}

test "the table parses sorted rows and refuses malformed ones" {
    var names: [4][]const u8 = undefined;
    var micros: [4]u64 = undefined;
    const table = try parse(header ++ "\t8500000\na b\t3\nc\t0\n", &names, &micros);
    try std.testing.expectEqual(@as(u64, 8_500_000), table.shard_us);
    try std.testing.expectEqual(@as(?u64, 3), table.find("a b"));
    try std.testing.expectEqual(@as(?u64, 0), table.find("c"));
    try std.testing.expectEqual(@as(?u64, null), table.find("b"));
    try std.testing.expectError(error.MissingHeader, parse("", names[0..0], micros[0..0]));
    try std.testing.expectError(error.InvalidHeader, parse("weights\t0\n", &names, &micros));
    const refusals = [_]struct { anyerror, []const u8 }{
        .{ error.Unsorted, header ++ "\t0\nb\t1\na\t1\n" },
        .{ error.Unsorted, header ++ "\t0\na\t1\na\t2\n" },
        .{ error.InvalidRow, header ++ "\t0\na\n" },
        .{ error.InvalidRow, header ++ "\t0\n\na\t1\n" },
    };
    for (refusals) |refusal| {
        try std.testing.expectError(refusal[0], parse(refusal[1], &names, &micros));
    }
    const two_rows = header ++ "\t0\na\t1\nb\t1\n";
    try std.testing.expectError(error.TooManyRows, parse(two_rows, names[0..1], micros[0..1]));
}

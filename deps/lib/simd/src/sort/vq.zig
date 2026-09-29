const std = @import("std");
const constants = @import("constants.zig");
const heap = @import("heap.zig");
const key = @import("key.zig");
const network = @import("network.zig");
const partition = @import("partition.zig");
const pivot = @import("pivot.zig");
const random = @import("random.zig");

pub const Error = error{InvalidK};
pub const maximum_levels: usize = 50;

pub fn sort(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
) void {
    var scratch = network.Scratch{};
    var state = initialState(values.len);
    const valid = values.len - partition.nanToBack(Key, values);
    sortRange(Key, direction, values[0..valid], &scratch, &state, maximum_levels);
}

pub fn partialSort(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
    k: usize,
) Error!void {
    if (k > values.len) return error.InvalidK;
    var scratch = network.Scratch{};
    var state = initialState(values.len);
    const valid = values.len - partition.nanToBack(Key, values);
    const prefix = @min(k, valid);
    if (prefix < valid) {
        selectRange(Key, direction, values[0..valid], prefix, &scratch, &state, maximum_levels);
    }
    sortRange(Key, direction, values[0..prefix], &scratch, &state, maximum_levels);
}

pub fn select(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
    k: usize,
) Error!void {
    if (k >= values.len) return error.InvalidK;
    var scratch = network.Scratch{};
    var state = initialState(values.len);
    const valid = values.len - partition.nanToBack(Key, values);
    if (k >= valid) return;
    selectRange(Key, direction, values[0..valid], k, &scratch, &state, maximum_levels);
}

pub fn haveFloat16() bool {
    return true;
}

pub fn haveFloat64() bool {
    return true;
}

fn initialState(count: usize) random.State {
    const size: u64 = @intCast(count);
    return random.State.init(
        0x243f_6a88_85a3_08d3 ^ size,
        0x1319_8a2e_0370_7344 ^ (size *% 0x9e37_79b9_7f4a_7c15),
    );
}

fn baseSort(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
    scratch: *network.Scratch,
) void {
    network.sort(Key, direction, values, scratch) catch unreachable;
}

fn sortRange(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
    scratch: *network.Scratch,
    state: *random.State,
    levels: usize,
) void {
    const capacity = comptime constants.baseCaseKeyCapacity(Key);
    var active = values;
    var remaining = levels;
    while (active.len > capacity) {
        if (remaining == 0) {
            heap.sort(Key, direction, active);
            return;
        }
        const selected = pivot.choose(Key, direction, active, state);
        const bounds = partition.around(Key, direction, active, selected);
        std.debug.assert(bounds.before < bounds.after);
        remaining -= 1;
        const left = active[0..bounds.before];
        const right = active[bounds.after..];
        if (left.len < right.len) {
            if (left.len > 1) sortRange(Key, direction, left, scratch, state, remaining);
            active = right;
        } else {
            if (right.len > 1) sortRange(Key, direction, right, scratch, state, remaining);
            active = left;
        }
    }
    baseSort(Key, direction, active, scratch);
}

fn selectRange(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
    k: usize,
    scratch: *network.Scratch,
    state: *random.State,
    levels: usize,
) void {
    std.debug.assert(k < values.len);
    const capacity = comptime constants.baseCaseKeyCapacity(Key);
    var active = values;
    var selected_index = k;
    var remaining = levels;
    while (active.len > capacity) {
        if (remaining == 0) {
            heap.sort(Key, direction, active);
            return;
        }
        const selected = pivot.choose(Key, direction, active, state);
        const bounds = partition.around(Key, direction, active, selected);
        std.debug.assert(bounds.before < bounds.after);
        remaining -= 1;
        if (selected_index < bounds.before) {
            active = active[0..bounds.before];
        } else if (selected_index >= bounds.after) {
            active = active[bounds.after..];
            selected_index -= bounds.after;
        } else {
            return;
        }
    }
    baseSort(Key, direction, active, scratch);
}

fn Order(comptime Key: type, comptime direction: key.Direction) type {
    return struct {
        fn lessThan(_: void, a: Key, b: Key) bool {
            return key.before(Key, direction, a, b);
        }
    };
}

fn fillU32(values: []u32) void {
    var state = random.State.init(0x736f_6d65_7073_6575, 0x646f_7261_6e64_6f6d);
    for (values) |*value| value.* = @truncate(state.next());
}

fn verifyIntegerSort(comptime Key: type) !void {
    const count = comptime constants.baseCaseKeyCapacity(Key) + 17;
    const UInt = @Int(.unsigned, @bitSizeOf(Key));
    var source: [count]Key = undefined;
    var state = random.State.init(0xa409_3822_299f_31d0, 0x082e_fa98_ec4e_6c89);
    for (&source) |*value| {
        const bits: UInt = @truncate(state.next());
        value.* = @bitCast(bits);
    }
    inline for (.{ key.Direction.ascending, key.Direction.descending }) |direction| {
        var values = source;
        var expected = source;
        std.mem.sort(Key, &expected, {}, Order(Key, direction).lessThan);
        sort(Key, direction, &values);
        try std.testing.expectEqualSlices(Key, &expected, &values);
    }
}

test "Highway VQSort public full sort crosses the base-case boundary" {
    var ascending: [1025]u32 = undefined;
    fillU32(&ascending);
    var expected_ascending = ascending;
    std.mem.sort(u32, &expected_ascending, {}, Order(u32, .ascending).lessThan);
    sort(u32, .ascending, &ascending);
    try std.testing.expectEqualSlices(u32, &expected_ascending, &ascending);

    var descending = expected_ascending;
    var expected_descending = descending;
    std.mem.sort(u32, &expected_descending, {}, Order(u32, .descending).lessThan);
    sort(u32, .descending, &descending);
    try std.testing.expectEqualSlices(u32, &expected_descending, &descending);
}

test "Highway VQSort public full sort covers every integer width" {
    try verifyIntegerSort(u16);
    try verifyIntegerSort(i16);
    try verifyIntegerSort(u32);
    try verifyIntegerSort(i32);
    try verifyIntegerSort(u64);
    try verifyIntegerSort(i64);
}

test "Highway VQSort public partial sort and select preserve their boundaries" {
    var source: [1537]u32 = undefined;
    fillU32(&source);
    var expected = source;
    std.mem.sort(u32, &expected, {}, Order(u32, .ascending).lessThan);

    var partial = source;
    try partialSort(u32, .ascending, &partial, 613);
    try std.testing.expectEqualSlices(u32, expected[0..613], partial[0..613]);
    for (partial[613..]) |value| try std.testing.expect(value >= partial[612]);

    var selected = source;
    try select(u32, .ascending, &selected, 613);
    try std.testing.expectEqual(expected[613], selected[613]);
    for (selected[0..613]) |value| try std.testing.expect(value <= selected[613]);
    for (selected[614..]) |value| try std.testing.expect(value >= selected[613]);

    var all = source;
    try partialSort(u32, .ascending, &all, all.len);
    try std.testing.expectEqualSlices(u32, &expected, &all);
}

test "Highway VQSort public recursion terminates equal and two-value inputs" {
    var equal = @as([4097]u32, @splat(17));
    sort(u32, .ascending, &equal);
    try partialSort(u32, .descending, &equal, 2048);
    try select(u32, .ascending, &equal, 3000);
    for (equal) |value| try std.testing.expectEqual(@as(u32, 17), value);

    var two: [4097]u32 = undefined;
    for (&two, 0..) |*value, index| value.* = @intCast(index & 1);
    sort(u32, .descending, &two);
    for (two[1..], 1..) |value, index| try std.testing.expect(two[index - 1] >= value);
}

test "Highway VQSort public recursion reaches the heap fallback" {
    var values: [513]u32 = undefined;
    fillU32(&values);
    var expected = values;
    std.mem.sort(u32, &expected, {}, Order(u32, .ascending).lessThan);
    var scratch = network.Scratch{};
    var state = initialState(values.len);
    sortRange(u32, .ascending, &values, &scratch, &state, 0);
    try std.testing.expectEqualSlices(u32, &expected, &values);

    fillU32(&values);
    std.mem.sort(u32, &expected, {}, Order(u32, .descending).lessThan);
    state = initialState(values.len);
    selectRange(u32, .descending, &values, 271, &scratch, &state, 0);
    try std.testing.expectEqual(expected[271], values[271]);
}

test "Highway VQSort public key records and uint128 retain key order" {
    var records: [513]key.K32V32 = undefined;
    for (&records, 0..) |*value, index| {
        value.* = key.K32V32.init(@intCast((index * 97) % 31), @intCast(index));
    }
    const original = records;
    sort(key.K32V32, .ascending, &records);
    for (records[1..], 1..) |value, index| try std.testing.expect(records[index - 1].key <= value.key);
    var expected_records = original;
    var actual_records = records;
    std.mem.sort(key.K32V32, &expected_records, {}, struct {
        fn lessThan(_: void, a: key.K32V32, b: key.K32V32) bool {
            return key.networkBefore(key.K32V32, .ascending, a, b);
        }
    }.lessThan);
    std.mem.sort(key.K32V32, &actual_records, {}, struct {
        fn lessThan(_: void, a: key.K32V32, b: key.K32V32) bool {
            return key.networkBefore(key.K32V32, .ascending, a, b);
        }
    }.lessThan);
    try std.testing.expectEqualSlices(key.K32V32, &expected_records, &actual_records);

    var partial_records = original;
    try partialSort(key.K32V32, .ascending, &partial_records, 211);
    for (partial_records[1..211], 1..) |value, index| {
        try std.testing.expect(partial_records[index - 1].key <= value.key);
    }
    for (partial_records[211..]) |value| try std.testing.expect(value.key >= partial_records[210].key);
    var selected_records = original;
    try select(key.K32V32, .descending, &selected_records, 211);
    for (selected_records[0..211]) |value| try std.testing.expect(value.key >= selected_records[211].key);
    for (selected_records[212..]) |value| try std.testing.expect(value.key <= selected_records[211].key);

    var wide: [257]u128 = undefined;
    for (&wide, 0..) |*value, index| {
        value.* = (@as(u128, @intCast(index * 131 + 7)) << 64) | @as(u128, @intCast(257 - index));
    }
    var expected_wide = wide;
    std.mem.sort(u128, &expected_wide, {}, Order(u128, .descending).lessThan);
    sort(u128, .descending, &wide);
    try std.testing.expectEqualSlices(u128, &expected_wide, &wide);

    var records64: [129]key.K64V64 = undefined;
    for (&records64, 0..) |*value, index| {
        value.* = key.K64V64.init(@intCast((index * 193) % 43), @intCast(index));
    }
    sort(key.K64V64, .descending, &records64);
    for (records64[1..], 1..) |value, index| {
        try std.testing.expect(records64[index - 1].key >= value.key);
    }
}

fn verifyFloatNaN(comptime Float: type, comptime direction: key.Direction) !void {
    var source: [521]Float = undefined;
    for (&source, 0..) |*value, index| {
        const magnitude: Float = @floatFromInt(index % 127);
        value.* = if (index & 1 == 0) magnitude else -magnitude;
    }
    source[7] = std.math.nan(Float);
    source[91] = std.math.nan(Float);
    source[173] = std.math.inf(Float);
    source[281] = std.math.nan(Float);
    source[407] = -std.math.inf(Float);
    source[503] = std.math.nan(Float);

    var expected_valid: [517]Float = undefined;
    var write: usize = 0;
    for (source) |value| {
        if (!std.math.isNan(value)) {
            expected_valid[write] = value;
            write += 1;
        }
    }
    try std.testing.expectEqual(expected_valid.len, write);
    std.mem.sort(Float, &expected_valid, {}, Order(Float, direction).lessThan);

    var full = source;
    sort(Float, direction, &full);
    try std.testing.expectEqualSlices(Float, &expected_valid, full[0..expected_valid.len]);
    for (full[expected_valid.len..]) |value| try std.testing.expect(std.math.isNan(value));

    var partial = source;
    try partialSort(Float, direction, &partial, 311);
    try std.testing.expectEqualSlices(Float, expected_valid[0..311], partial[0..311]);
    for (partial[expected_valid.len..]) |value| try std.testing.expect(std.math.isNan(value));

    var partial_all = source;
    try partialSort(Float, direction, &partial_all, partial_all.len);
    try std.testing.expectEqualSlices(Float, &expected_valid, partial_all[0..expected_valid.len]);
    for (partial_all[expected_valid.len..]) |value| try std.testing.expect(std.math.isNan(value));

    var selected = source;
    try select(Float, direction, &selected, 311);
    try std.testing.expectEqual(expected_valid[311], selected[311]);
    for (selected[expected_valid.len..]) |value| try std.testing.expect(std.math.isNan(value));

    var nan_selected = source;
    try select(Float, direction, &nan_selected, 519);
    try std.testing.expect(std.math.isNan(nan_selected[519]));
    var infinity_count: usize = 0;
    for (nan_selected[0..expected_valid.len]) |value| {
        if (std.math.isInf(value)) infinity_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), infinity_count);
}

test "Highway VQSort public float operations move NaN behind real infinities" {
    inline for (.{ f16, f32, f64 }) |Float| {
        try verifyFloatNaN(Float, .ascending);
        try verifyFloatNaN(Float, .descending);
    }
}

test "Highway VQSort public k contracts reject before mutation" {
    var values = [_]f32{ 3, std.math.nan(f32), 1 };
    const expected_bits = [_]u32{ @bitCast(values[0]), @bitCast(values[1]), @bitCast(values[2]) };
    try std.testing.expectError(error.InvalidK, partialSort(f32, .ascending, &values, 4));
    try std.testing.expectError(error.InvalidK, select(f32, .ascending, &values, 3));
    for (values, expected_bits) |value, bits| try std.testing.expectEqual(bits, @as(u32, @bitCast(value)));
    try partialSort(f32, .ascending, &values, 0);
    try std.testing.expect(haveFloat16());
    try std.testing.expect(haveFloat64());
}

fn oracleFold(digest: *u64, value: anytype) void {
    digest.* = (digest.* ^ @as(u64, @intCast(value))) *% 0x0000_0100_0000_01b3;
}

fn oracleMix(input: u64) u64 {
    var value = input;
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

fn foldIntegerOracle(digest: *u64) void {
    const count = 1021;
    var u16_values: [count]u16 = undefined;
    var i16_values: [count]i16 = undefined;
    var u32_values: [count]u32 = undefined;
    var i32_values: [count]i32 = undefined;
    var u64_values: [count]u64 = undefined;
    var i64_values: [count]i64 = undefined;
    for (0..count) |index| {
        const permutation = (index * 73 + 19) % count;
        u16_values[index] = @intCast(permutation);
        i16_values[index] = @intCast(@as(i32, @intCast(permutation)) - 510);
        u32_values[index] = @truncate(oracleMix(index + 11));
        i32_values[index] = @bitCast(@as(u32, @truncate(oracleMix(index + 23))));
        u64_values[index] = oracleMix(index + 37);
        i64_values[index] = @bitCast(oracleMix(index + 41));
    }
    sort(u16, .ascending, &u16_values);
    sort(i16, .descending, &i16_values);
    sort(u32, .ascending, &u32_values);
    sort(i32, .descending, &i32_values);
    sort(u64, .ascending, &u64_values);
    sort(i64, .descending, &i64_values);
    for (0..count) |index| {
        oracleFold(digest, u16_values[index]);
        oracleFold(digest, @as(u16, @bitCast(i16_values[index])));
        oracleFold(digest, u32_values[index]);
        oracleFold(digest, @as(u32, @bitCast(i32_values[index])));
        oracleFold(digest, u64_values[index]);
        oracleFold(digest, @as(u64, @bitCast(i64_values[index])));
    }
}

fn foldFloatOracle(digest: *u64) void {
    const count = 1021;
    var f32_values: [count]f32 = undefined;
    var f64_values: [count]f64 = undefined;
    for (0..count) |index| {
        const value: i32 = @as(i32, @intCast((index * 97 + 3) % count)) - 510;
        f32_values[index] = @floatFromInt(value);
        f64_values[index] = @floatFromInt(value);
    }
    f32_values[17] = std.math.inf(f32);
    f32_values[93] = std.math.nan(f32);
    f32_values[511] = std.math.nan(f32);
    f32_values[900] = -std.math.inf(f32);
    f64_values[29] = std.math.inf(f64);
    f64_values[113] = std.math.nan(f64);
    f64_values[617] = std.math.nan(f64);
    f64_values[901] = -std.math.inf(f64);
    sort(f32, .ascending, &f32_values);
    sort(f64, .descending, &f64_values);
    for (0..count) |index| {
        oracleFold(digest, @as(u32, @bitCast(f32_values[index])));
        oracleFold(digest, @as(u64, @bitCast(f64_values[index])));
    }
}

fn foldWideOracle(digest: *u64) !void {
    const count = 1021;
    var kv32: [count]key.K32V32 = undefined;
    for (&kv32, 0..) |*value, index| {
        value.* = .{
            .value = @truncate(oracleMix(index + 51)),
            .key = @intCast((index * 101 + 7) % count),
        };
    }
    sort(key.K32V32, .ascending, &kv32);
    for (kv32) |value| {
        oracleFold(digest, value.value);
        oracleFold(digest, value.key);
    }
    try std.testing.expectEqual(@as(u64, 6_939_292_972_457_705_748), digest.*);

    const wide_count = 257;
    var u128_values: [wide_count]u128 = undefined;
    var kv64: [wide_count]key.K64V64 = undefined;
    for (0..wide_count) |index| {
        u128_values[index] = @as(u128, oracleMix(index + 61)) |
            (@as(u128, oracleMix(index + 71)) << 64);
        kv64[index] = .{
            .value = oracleMix(index + 81),
            .key = @intCast((index * 193 + 11) % wide_count),
        };
    }
    sort(u128, .descending, &u128_values);
    sort(key.K64V64, .descending, &kv64);
    for (0..wide_count) |index| {
        oracleFold(digest, @as(u64, @truncate(u128_values[index])));
        oracleFold(digest, @as(u64, @truncate(u128_values[index] >> 64)));
        oracleFold(digest, kv64[index].value);
        oracleFold(digest, kv64[index].key);
    }
}

fn foldPartialSelectOracle(digest: *u64) !void {
    const count = 1021;
    var partial: [count]u32 = undefined;
    for (&partial, 0..) |*value, index| value.* = @truncate(oracleMix(index + 91));
    try partialSort(u32, .ascending, &partial, 317);
    for (partial[0..317]) |value| oracleFold(digest, value);
    try std.testing.expectEqual(@as(u64, 15_502_069_084_655_779_296), digest.*);

    var selected: [count]u64 = undefined;
    for (&selected, 0..) |*value, index| value.* = oracleMix(index + 101);
    try select(u64, .descending, &selected, 503);
    oracleFold(digest, selected[503]);
    var violations: u64 = 0;
    for (selected[0..503]) |value| violations += @intFromBool(value < selected[503]);
    for (selected[504..]) |value| violations += @intFromBool(value > selected[503]);
    oracleFold(digest, violations);
    try std.testing.expectEqual(@as(u64, 13_890_455_305_228_908_481), digest.*);

    const nan_count = 521;
    var nan_values: [nan_count]f32 = undefined;
    for (&nan_values, 0..) |*value, index| value.* = @floatFromInt((index * 67 + 5) % 509);
    nan_values[13] = std.math.nan(f32);
    nan_values[107] = std.math.inf(f32);
    nan_values[211] = std.math.nan(f32);
    nan_values[401] = -std.math.inf(f32);
    nan_values[503] = std.math.nan(f32);
    var nan_partial = nan_values;
    try partialSort(f32, .descending, &nan_partial, 300);
    for (nan_partial[0..300]) |value| oracleFold(digest, @as(u32, @bitCast(value)));
    var nan_selected = nan_values;
    try select(f32, .ascending, &nan_selected, 519);
    var nans: u64 = 0;
    var infinities: u64 = 0;
    for (nan_selected) |value| {
        nans += @intFromBool(std.math.isNan(value));
        infinities += @intFromBool(std.math.isInf(value));
    }
    oracleFold(digest, @intFromBool(std.math.isNan(nan_selected[519])));
    oracleFold(digest, nans);
    oracleFold(digest, infinities);
}

test "pinned Highway VQSort public APIs agree across full partial select and NaN" {
    var digest: u64 = 0xcbf2_9ce4_8422_2325;
    foldIntegerOracle(&digest);
    try std.testing.expectEqual(@as(u64, 2_625_724_195_073_583_756), digest);
    foldFloatOracle(&digest);
    try std.testing.expectEqual(@as(u64, 14_271_760_640_035_470_920), digest);
    try foldWideOracle(&digest);
    try std.testing.expectEqual(@as(u64, 8_362_152_917_260_480_414), digest);
    try foldPartialSelectOracle(&digest);
    try std.testing.expectEqual(@as(u64, 6_678_231_707_808_607_537), digest);
}
